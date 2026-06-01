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

@Suite("DXClickHouse Array(Tuple) column")
struct ClickHouseArrayOfTupleColumnTests {

    struct Row: Codable, Sendable, Equatable {
        let items: ClickHouseArrayOfTuple
    }

    @Test("Array(Tuple(UInt64, String)) writes cumulative offsets then flattened firsts then seconds")
    func encodeArrayOfTupleBytes() throws {
        let columns = try ClickHouseRowEncoder().encode([
            Row(items: ClickHouseArrayOfTuple.uint64String([(1, "a"), (2, "b")])),
            Row(items: ClickHouseArrayOfTuple.uint64String([(3, "c")])),
        ])
        #expect(columns[0].column.typeName == "Array(Tuple(UInt64, String))")
        let packet = try ClickHouseBlockWriter.encodeDataPacket(
            columns: columns,
            revision: ClickHouseBlockWriter.revisionWithCustomSerialization
        )
        let expected = Self.uint64LE(2) + Self.uint64LE(3)
            + Self.uint64LE(1) + Self.uint64LE(2) + Self.uint64LE(3)
            + [1, 97] + [1, 98] + [1, 99]
        #expect(Array(packet.suffix(expected.count)) == expected)
    }

    @Test("Array(Tuple(UInt64, String)) round-trips, including an empty-tuple row")
    func roundTripArrayOfTupleWithEmptyRow() throws {
        let rows = [
            Row(items: ClickHouseArrayOfTuple.uint64String([])),
            Row(items: ClickHouseArrayOfTuple.uint64String([(10, "x"), (20, "y")])),
        ]
        let decoded = try Self.roundTrip(rows: rows, bodyLength: 16 + 16 + 4)
        #expect(decoded == rows)
    }

    @Test("Array(Tuple(UInt64, String)) type name round-trips through parseTypedColumns")
    func arrayOfTupleTypeNameRoundTrips() throws {
        let body: [UInt8] = Self.uint64LE(1) + Self.uint64LE(7) + [1, 107]
        let block = ClickHouseBlock(
            rowCount: 1, columnCount: 1,
            columnNames: ["items"],
            columnTypes: ["Array(Tuple(UInt64, String))"],
            bodyStart: 0, bodyLength: body.count
        )
        let decoded = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        #expect(decoded[0].column.typeName == "Array(Tuple(UInt64, String))")
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: decoded, rowCount: 1)
        #expect(rows[0].items.uint64First(at: 0) == 7)
        #expect(rows[0].items.stringSecond(at: 0) == "k")
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
