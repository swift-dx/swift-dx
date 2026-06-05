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

@testable import DXClickHouse
import Testing

// ClickHouse stores Bool as a single 0/1 byte, so an Array(Bool) column is
// wire-identical to Array(UInt8) with the bytes read as booleans. Before
// this, the array element-type dispatch had no Bool case, so a SELECT from
// a table with an Array(Bool) column failed with "unsupported Array
// element type Bool" — and there was no way to encode one. These tests
// cover the round trip and the decode of a server-shaped block.
@Suite("Array(Bool) columns encode and decode")
struct ArrayBoolColumnTests {

    private struct Row: Codable, Sendable, Equatable {
        let flags: ClickHouseArray
    }

    @Test("Array(Bool) declares the right type name and round-trips")
    func roundTrip() throws {
        let rows = [
            Row(flags: ClickHouseArray.bools([true])),
            Row(flags: ClickHouseArray.bools([false, true, false])),
        ]
        let columns = try ClickHouseRowEncoder().encode(rows)
        #expect(columns[0].column.typeName == "Array(Bool)")

        let packet = try ClickHouseBlockWriter.encodeDataPacket(
            columns: columns,
            revision: ClickHouseBlockWriter.revisionWithCustomSerialization
        )
        // offsets [1, 4] = 16 bytes, then 4 single-byte elements.
        let body = Array(packet.suffix(16 + 4))
        let block = ClickHouseBlock(
            rowCount: rows.count, columnCount: 1,
            columnNames: [columns[0].name],
            columnTypes: [columns[0].column.typeName],
            bodyStart: 0, bodyLength: body.count
        )
        let decoded = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        let result = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: decoded, rowCount: rows.count)
        #expect(result == rows)
        #expect(result[0].flags.bools == [true])
        #expect(result[1].flags.bools == [false, true, false])
    }

    @Test("decoding a server Array(Bool) block reads each byte as a boolean")
    func decodeFromServerBytes() throws {
        // Two rows: [true], then [false, true]. Cumulative offsets are
        // [1, 3] (UInt64 LE), then element bytes 1, 0, 1.
        var body: [UInt8] = []
        for offset in [UInt64(1), UInt64(3)] {
            withUnsafeBytes(of: offset.littleEndian) { body.append(contentsOf: $0) }
        }
        body.append(contentsOf: [1, 0, 1])

        let block = ClickHouseBlock(
            rowCount: 2, columnCount: 1,
            columnNames: ["flags"],
            columnTypes: ["Array(Bool)"],
            bodyStart: 0, bodyLength: body.count
        )
        let columns = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 2)
        #expect(rows[0].flags.element == .bool)
        #expect(rows[0].flags.bools == [true])
        #expect(rows[1].flags.bools == [false, true])
    }
}
