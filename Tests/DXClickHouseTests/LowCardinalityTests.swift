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

// These tests pin the byte layout this implementation produces and prove
// the encoder and decoder are mutually consistent (encode → bytes →
// decode reproduces the original values). Server acceptance of the exact
// serialization-flag word is covered by the gated LowCardinality
// integration test.
@Suite("DXClickHouse LowCardinality column")
struct ClickHouseLowCardinalityTests {

    struct StringRow: Codable, Sendable, Equatable {
        let tag: ClickHouseLowCardinality
    }

    @Test("LowCardinality(String) builds an inline dictionary + index stream")
    func encodeLowCardinalityString() throws {
        let columns = try ClickHouseRowEncoder().encode([
            StringRow(tag: ClickHouseLowCardinality("a")),
            StringRow(tag: ClickHouseLowCardinality("b")),
            StringRow(tag: ClickHouseLowCardinality("a")),
        ])
        #expect(columns[0].column.typeName == "LowCardinality(String)")
        let packet = try ClickHouseBlockWriter.encodeDataPacket(
            columns: columns,
            revision: ClickHouseBlockWriter.revisionWithCustomSerialization
        )
        let expected = Self.stringBody()
        #expect(Array(packet.suffix(expected.count)) == expected)
    }

    @Test("LowCardinality(String) decodes the dictionary + indices back to per-row values")
    func decodeLowCardinalityString() throws {
        let body = Self.stringBody()
        let block = ClickHouseBlock(
            rowCount: 3, columnCount: 1,
            columnNames: ["tag"],
            columnTypes: ["LowCardinality(String)"],
            bodyStart: 0, bodyLength: body.count
        )
        let columns = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        let rows = try ClickHouseCodableDecoder.decodeRows(type: StringRow.self, columns: columns, rowCount: 3)
        #expect(rows == [
            StringRow(tag: ClickHouseLowCardinality("a")),
            StringRow(tag: ClickHouseLowCardinality("b")),
            StringRow(tag: ClickHouseLowCardinality("a")),
        ])
    }

    @Test("LowCardinality(FixedString(2)) round-trips through encode and decode")
    func roundTripLowCardinalityFixedString() throws {
        let columns = try ClickHouseRowEncoder().encode([
            StringRow(tag: ClickHouseLowCardinality.fixedString([97, 98], length: 2)),
            StringRow(tag: ClickHouseLowCardinality.fixedString([99, 100], length: 2)),
            StringRow(tag: ClickHouseLowCardinality.fixedString([97, 98], length: 2)),
        ])
        #expect(columns[0].column.typeName == "LowCardinality(FixedString(2))")
        let packet = try ClickHouseBlockWriter.encodeDataPacket(
            columns: columns,
            revision: ClickHouseBlockWriter.revisionWithCustomSerialization
        )
        let expected = Self.fixedBody()
        #expect(Array(packet.suffix(expected.count)) == expected)

        let block = ClickHouseBlock(
            rowCount: 3, columnCount: 1,
            columnNames: ["tag"],
            columnTypes: ["LowCardinality(FixedString(2))"],
            bodyStart: 0, bodyLength: expected.count
        )
        let decoded = try expected.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        let rows = try ClickHouseCodableDecoder.decodeRows(type: StringRow.self, columns: decoded, rowCount: 3)
        #expect(rows == [
            StringRow(tag: ClickHouseLowCardinality.fixedString([97, 98], length: 2)),
            StringRow(tag: ClickHouseLowCardinality.fixedString([99, 100], length: 2)),
            StringRow(tag: ClickHouseLowCardinality.fixedString([97, 98], length: 2)),
        ])
    }

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    // version=1, flags=HasAdditionalKeys|width0, dictSize=2, dict["a","b"]
    // as length-prefixed strings, indicesCount=3, indices=[0,1,0] (1 byte each)
    private static func stringBody() -> [UInt8] {
        uint64LE(1) + uint64LE(0x0200) + uint64LE(2) + [1, 97] + [1, 98] + uint64LE(3) + [0, 1, 0]
    }

    // Same shape with a FixedString(2) dictionary (2 raw bytes per entry).
    private static func fixedBody() -> [UInt8] {
        uint64LE(1) + uint64LE(0x0200) + uint64LE(2) + [97, 98] + [99, 100] + uint64LE(3) + [0, 1, 0]
    }
}
