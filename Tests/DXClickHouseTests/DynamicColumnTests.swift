//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftDX open source project
//
// Copyright (c) 2026 SwiftDX Contributors
// Licensed under Apache License v2.0. See LICENSE for license information.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DXClickHouse
import Foundation
import Testing

@Suite("DXClickHouse Dynamic column")
struct ClickHouseDynamicColumnTests {

    struct Row: Codable, Sendable, Equatable {
        let value: ClickHouseDynamic
    }

    @Test("decode rejects an out-of-range Dynamic discriminator instead of trapping")
    func rejectsOutOfRangeDynamicDiscriminator() {
        let columns: [ClickHouseNamedColumn] = [
            ClickHouseNamedColumn(name: "value", column: .dynamic(members: [.string, .uint64], discriminators: [9], values: [[]])),
        ]
        var stage = "none"
        do {
            _ = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 1)
        } catch {
            if case .protocolError(let caught, _) = error { stage = caught }
        }
        #expect(stage == "decoder.dynamic")
    }

    @Test("Dynamic writes structure prefix, member names, then the embedded Variant body")
    func encodeDynamicBytes() throws {
        let columns = try ClickHouseRowEncoder().encode([
            Row(value: .string("hello")),
            Row(value: .uint64(42)),
            Row(value: .null),
        ])
        #expect(columns[0].column.typeName == "Dynamic")
        let packet = try ClickHouseBlockWriter.encodeDataPacket(
            columns: columns,
            revision: ClickHouseBlockWriter.revisionWithCustomSerialization
        )
        // Structure version 2 (native INSERT shape: no max-dynamic-types
        // field), ntypes 2, member names "String" and "UInt64" (sorted),
        // then the embedded Variant body: mode 8 (0), then global
        // discriminators. The global discriminator of each member is its
        // position among the sorted real members plus the hidden
        // SharedVariant: sorted ["SharedVariant","String","UInt64"] gives
        // String=1, UInt64=2, NULL=255. Sub-columns follow in member-name
        // order: String "hello" length-prefixed, then UInt64 42 LE.
        let expected = Self.uint64LE(2)
            + [0x02]
            + [6, 83, 116, 114, 105, 110, 103]
            + [6, 85, 73, 110, 116, 54, 52]
            + Self.uint64LE(0)
            + [0x01, 0x02, 0xFF]
            + [5, 104, 101, 108, 108, 111]
            + Self.uint64LE(42)
        #expect(Array(packet.suffix(expected.count)) == expected)
    }

    @Test("Dynamic round-trips a String, a UInt64, and a NULL row through the writer and decoder")
    func roundTripDynamic() throws {
        let rows = [
            Row(value: .string("hello")),
            Row(value: .uint64(42)),
            Row(value: .null),
        ]
        // version 8 + ntypes 1 + "String" 7 + "UInt64" 7 + mode 8 + disc 3
        // + "hello" 6 + UInt64 8 = 48 bytes. ntypes is a single-byte
        // uvarint (value 2); V2 carries no max-dynamic-types field.
        let bodyLength = 8 + 1 + 7 + 7 + 8 + 3 + 6 + 8
        let decoded = try Self.roundTrip(rows: rows, bodyLength: bodyLength)
        #expect(decoded == rows)
        #expect(decoded[0].value.value == .string("hello"))
        #expect(decoded[1].value.value == .uint64(42))
        #expect(decoded[2].value.value == .null)
    }

    @Test("Dynamic reader re-maps non-contiguous server discriminators to member positions")
    func decodesNonContiguousDiscriminators() throws {
        // ClickHouse emits non-contiguous global discriminators because the
        // embedded Variant carries a hidden SharedVariant member that takes
        // one discriminator slot. Members [Float64, Int64, String] sort with
        // SharedVariant to ["Float64","Int64","SharedVariant","String"], so
        // their global discriminators are {0, 1, 3} (slot 2 is the
        // SharedVariant). This is the V1 shape ClickHouse emits on
        // SELECT ... FORMAT Native. Rows: [String "zz", Int64 -1, Float64 2.5].
        let body = Self.uint64LE(1)
            + [0x03, 0x03]
            + [7, 70, 108, 111, 97, 116, 54, 52]
            + [5, 73, 110, 116, 54, 52]
            + [6, 83, 116, 114, 105, 110, 103]
            + Self.uint64LE(0)
            + [0x03, 0x01, 0x00]
            + Self.float64LE(2.5)
            + Self.int64LE(-1)
            + [2, 122, 122]
        let block = ClickHouseBlock(
            rowCount: 3, columnCount: 1,
            columnNames: ["value"],
            columnTypes: ["Dynamic"],
            bodyStart: 0, bodyLength: body.count
        )
        let decoded = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        #expect(decoded[0].column.typeName == "Dynamic")
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: decoded, rowCount: 3)
        #expect(rows[0].value.value == .string("zz"))
        #expect(rows[1].value.value == .int64(-1))
        #expect(rows[2].value.value == .float64(2.5))
    }

    private static func roundTrip(rows: [Row], bodyLength: Int) throws -> [Row] {
        let columns = try ClickHouseRowEncoder().encode(rows)
        let packet = try ClickHouseBlockWriter.encodeDataPacket(
            columns: columns,
            revision: ClickHouseBlockWriter.revisionWithCustomSerialization
        )
        let body = Array(packet.suffix(bodyLength))
        let block = ClickHouseBlock(
            rowCount: rows.count, columnCount: 1,
            columnNames: [columns[0].name],
            columnTypes: [columns[0].column.typeName],
            bodyStart: 0, bodyLength: body.count
        )
        let decoded = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        return try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: decoded, rowCount: rows.count)
    }

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func int64LE(_ value: Int64) -> [UInt8] {
        uint64LE(UInt64(bitPattern: value))
    }

    private static func float64LE(_ value: Double) -> [UInt8] {
        uint64LE(value.bitPattern)
    }
}
