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

@Suite("DXClickHouse Variant column")
struct ClickHouseVariantColumnTests {

    struct Row: Codable, Sendable, Equatable {
        let value: ClickHouseVariant
    }

    @Test("Variant(String, UInt64) writes mode prefix, discriminators, then per-member sub-columns")
    func encodeVariantBytes() throws {
        let columns = try ClickHouseRowEncoder().encode([
            Row(value: ClickHouseVariant.stringOrUInt64(.string("hello"))),
            Row(value: ClickHouseVariant.stringOrUInt64(.uint64(42))),
            Row(value: ClickHouseVariant.stringOrUInt64(.null)),
        ])
        #expect(columns[0].column.typeName == "Variant(String, UInt64)")
        let packet = try ClickHouseBlockWriter.encodeDataPacket(
            columns: columns,
            revision: ClickHouseBlockWriter.revisionWithCustomSerialization
        )
        // 8-byte mode prefix (0), discriminators [String=0, UInt64=1, NULL=255],
        // then String sub-column "hello" length-prefixed, then UInt64 sub-column 42 LE.
        let expected = Self.uint64LE(0)
            + [0x00, 0x01, 0xFF]
            + [5, 104, 101, 108, 108, 111]
            + Self.uint64LE(42)
        #expect(Array(packet.suffix(expected.count)) == expected)
    }

    @Test("Variant(String, UInt64) round-trips a String, a UInt64, and a NULL row")
    func roundTripVariant() throws {
        let rows = [
            Row(value: ClickHouseVariant.stringOrUInt64(.string("hello"))),
            Row(value: ClickHouseVariant.stringOrUInt64(.uint64(42))),
            Row(value: ClickHouseVariant.stringOrUInt64(.null)),
        ]
        // mode 8 + disc 3 + "hello" (6) + UInt64 (8) = 25 bytes.
        let decoded = try Self.roundTrip(rows: rows, bodyLength: 8 + 3 + 6 + 8)
        #expect(decoded == rows)
        #expect(decoded[0].value.value == .string("hello"))
        #expect(decoded[1].value.value == .uint64(42))
        #expect(decoded[2].value.value == .null)
    }

    @Test("Variant members are stored in canonical alphabetical order regardless of declaration order")
    func memberSortNormalizes() throws {
        let column = try ClickHouseRowEncoder().encode([
            Row(value: ClickHouseVariant(members: [.uint64, .string], value: .string("z"))),
        ])
        #expect(column[0].column.typeName == "Variant(String, UInt64)")
    }

    @Test("Variant type name round-trips through parseTypedColumns")
    func variantTypeNameRoundTrips() throws {
        // mode 8, disc [0] (String), then String sub-column "k" length-prefixed.
        let body: [UInt8] = Self.uint64LE(0) + [0x00] + [1, 107]
        let block = ClickHouseBlock(
            rowCount: 1, columnCount: 1,
            columnNames: ["value"],
            columnTypes: ["Variant(String, UInt64)"],
            bodyStart: 0, bodyLength: body.count
        )
        let decoded = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        #expect(decoded[0].column.typeName == "Variant(String, UInt64)")
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: decoded, rowCount: 1)
        #expect(rows[0].value.value == .string("k"))
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
}
