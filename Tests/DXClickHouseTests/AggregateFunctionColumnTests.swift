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

@Suite("DXClickHouse AggregateFunction column")
struct ClickHouseAggregateFunctionColumnTests {

    struct Row: Codable, Sendable, Equatable {
        let state: ClickHouseAggregateState
    }

    @Test("AggregateFunction column body is the per-row states concatenated with no framing")
    func encodeAggregateFunctionBytes() throws {
        let columns = try ClickHouseRowEncoder().encode([
            Row(state: ClickHouseAggregateState(signature: "sum, UInt64", bytes: Self.uint64LE(0))),
            Row(state: ClickHouseAggregateState(signature: "sum, UInt64", bytes: Self.uint64LE(10))),
            Row(state: ClickHouseAggregateState(signature: "sum, UInt64", bytes: Self.uint64LE(20))),
        ])
        #expect(columns[0].column.typeName == "AggregateFunction(sum, UInt64)")
        let packet = try ClickHouseBlockWriter.encodeDataPacket(
            columns: columns,
            revision: ClickHouseBlockWriter.revisionWithCustomSerialization
        )
        let expected = Self.uint64LE(0) + Self.uint64LE(10) + Self.uint64LE(20)
        #expect(Array(packet.suffix(expected.count)) == expected)
    }

    @Test("AggregateFunction(sum, UInt64) round-trips three 8-byte states")
    func roundTripAggregateFunction() throws {
        let rows = [
            Row(state: ClickHouseAggregateState(signature: "sum, UInt64", bytes: Self.uint64LE(0))),
            Row(state: ClickHouseAggregateState(signature: "sum, UInt64", bytes: Self.uint64LE(10))),
            Row(state: ClickHouseAggregateState(signature: "sum, UInt64", bytes: Self.uint64LE(20))),
        ]
        let decoded = try Self.roundTrip(rows: rows, bodyLength: 3 * 8)
        #expect(decoded == rows)
        #expect(decoded[0].state.bytes == Self.uint64LE(0))
        #expect(decoded[1].state.bytes == Self.uint64LE(10))
        #expect(decoded[2].state.bytes == Self.uint64LE(20))
        #expect(decoded[0].state.signature == "sum, UInt64")
    }

    @Test("AggregateFunction column body parses directly from pinned wire bytes")
    func parsePinnedBytes() throws {
        let body = Self.uint64LE(6) + Self.uint64LE(0) + Self.uint64LE(0)
        let block = ClickHouseBlock(
            rowCount: 3, columnCount: 1,
            columnNames: ["state"],
            columnTypes: ["AggregateFunction(sum, UInt64)"],
            bodyStart: 0, bodyLength: body.count
        )
        let decoded = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        #expect(decoded[0].column.typeName == "AggregateFunction(sum, UInt64)")
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: decoded, rowCount: 3)
        #expect(rows[0].state.bytes == Self.uint64LE(6))
        #expect(rows[1].state.bytes == Self.uint64LE(0))
        #expect(rows[2].state.bytes == Self.uint64LE(0))
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
