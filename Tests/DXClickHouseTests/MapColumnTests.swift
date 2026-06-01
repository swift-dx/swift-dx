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

@Suite("DXClickHouse Map column")
struct ClickHouseMapColumnTests {

    struct Row: Codable, Sendable, Equatable {
        let attributes: ClickHouseMap
    }

    @Test("Map(String, UInt64) writes cumulative offsets then flattened keys then values")
    func encodeMapBytes() throws {
        let columns = try ClickHouseRowEncoder().encode([
            Row(attributes: ClickHouseMap.stringToUInt64([("a", 1), ("b", 2)])),
            Row(attributes: ClickHouseMap.stringToUInt64([("c", 3)])),
        ])
        #expect(columns[0].column.typeName == "Map(String, UInt64)")
        let packet = try ClickHouseBlockWriter.encodeDataPacket(
            columns: columns,
            revision: ClickHouseBlockWriter.revisionWithCustomSerialization
        )
        // offsets [2, 3] as UInt64 LE, then keys "a","b","c" length-prefixed,
        // then values [1, 2, 3] as UInt64 LE.
        let expected = Self.uint64LE(2) + Self.uint64LE(3)
            + [1, 97] + [1, 98] + [1, 99]
            + Self.uint64LE(1) + Self.uint64LE(2) + Self.uint64LE(3)
        #expect(Array(packet.suffix(expected.count)) == expected)
    }

    @Test("Map(String, UInt64) round-trips, including an empty-map row")
    func roundTripMapWithEmptyRow() throws {
        let rows = [
            Row(attributes: ClickHouseMap.stringToUInt64([])),
            Row(attributes: ClickHouseMap.stringToUInt64([("x", 10), ("y", 20)])),
        ]
        // offsets [0, 2] = 16 bytes, then 2 keys "x","y" = 4 bytes, then
        // 2 values * 8 bytes = 16 bytes.
        let decoded = try Self.roundTrip(rows: rows, bodyLength: 16 + 4 + 16)
        #expect(decoded == rows)
    }

    @Test("Map(String, UInt64) type name round-trips through parseTypedColumns")
    func mapTypeNameRoundTrips() throws {
        // offsets [1] = 8 bytes, then key "k" length-prefixed, then value 7 LE.
        let body: [UInt8] = Self.uint64LE(1) + [1, 107] + Self.uint64LE(7)
        let block = ClickHouseBlock(
            rowCount: 1, columnCount: 1,
            columnNames: ["attributes"],
            columnTypes: ["Map(String, UInt64)"],
            bodyStart: 0, bodyLength: body.count
        )
        let decoded = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        #expect(decoded[0].column.typeName == "Map(String, UInt64)")
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: decoded, rowCount: 1)
        #expect(rows[0].attributes.stringKeys == ["k"])
        #expect(rows[0].attributes.uint64Value(at: 0) == 7)
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
