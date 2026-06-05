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

@Suite("DXClickHouse Array column")
struct ClickHouseArrayColumnTests {

    struct Row: Codable, Sendable, Equatable {
        let tags: ClickHouseArray
    }

    @Test("Array(String) writes cumulative offsets then the flattened inner column")
    func encodeArrayStringBytes() throws {
        let columns = try ClickHouseRowEncoder().encode([
            Row(tags: ClickHouseArray.strings(["a", "b"])),
            Row(tags: ClickHouseArray.strings(["c"])),
        ])
        #expect(columns[0].column.typeName == "Array(String)")
        let packet = try ClickHouseBlockWriter.encodeDataPacket(
            columns: columns,
            revision: ClickHouseBlockWriter.revisionWithCustomSerialization
        )
        // offsets [2, 3] as UInt64 LE, then "a","b","c" length-prefixed.
        let expected = Self.uint64LE(2) + Self.uint64LE(3) + [1, 97] + [1, 98] + [1, 99]
        #expect(Array(packet.suffix(expected.count)) == expected)
    }

    @Test("Array(String) round-trips, including an empty row")
    func roundTripArrayStringWithEmptyRow() throws {
        let rows = [
            Row(tags: ClickHouseArray.strings([])),
            Row(tags: ClickHouseArray.strings(["x", "y"])),
        ]
        // offsets [0, 2] = 16 bytes, then "x","y" = 4 bytes.
        let decoded = try Self.roundTrip(rows: rows, bodyLength: 16 + 4)
        #expect(decoded == rows)
    }

    @Test("Array(Int64) round-trips with little-endian fixed-width elements")
    func roundTripArrayInt64() throws {
        let rows = [
            Row(tags: ClickHouseArray.int64s([10])),
            Row(tags: ClickHouseArray.int64s([20, 30])),
        ]
        // offsets [1, 3] = 16 bytes, then 3 Int64 = 24 bytes.
        let decoded = try Self.roundTrip(rows: rows, bodyLength: 16 + 24)
        #expect(decoded == rows)
    }

    @Test("Array(FixedString(2)) round-trips fixed-width elements")
    func roundTripArrayFixedString() throws {
        let rows = [
            Row(tags: ClickHouseArray.fixedStrings([[97, 98]], length: 2)),
            Row(tags: ClickHouseArray.fixedStrings([[99, 100], [101, 102]], length: 2)),
        ]
        #expect(rows[0].tags.element == .fixedString(length: 2))
        // offsets [1, 3] = 16 bytes, then 3 elements * 2 bytes = 6 bytes.
        let decoded = try Self.roundTrip(rows: rows, bodyLength: 16 + 6)
        #expect(decoded == rows)
    }

    @Test("decode rejects a malformed Array offset above Int.max instead of trapping")
    func rejectsOversizedArrayOffset() {
        // Array(UInt8), one row, whose single cumulative element-count
        // offset has the high bit set (> Int.max). A corrupt or truncated
        // block must surface a typed error rather than trap when the
        // server-controlled offset is converted to Int.
        let body = Self.uint64LE(0x8000_0000_0000_0000)
        let block = ClickHouseBlock(
            rowCount: 1, columnCount: 1,
            columnNames: ["values"],
            columnTypes: ["Array(UInt8)"],
            bodyStart: 0, bodyLength: body.count
        )
        #expect(Self.parseStage(block: block, body: body) == "decoder.array")
    }

    @Test("decode rejects a malformed intermediate Array offset above Int.max instead of trapping")
    func rejectsOversizedIntermediateOffset() {
        // Two rows. The final cumulative offset (5) passes the bytes-remaining
        // bound, but the intermediate offset has the high bit set (> Int.max)
        // and reaches the per-row grouping. Converting it to Int unchecked
        // would trap; the decode must surface a typed error instead.
        let body = Self.uint64LE(0x8000_0000_0000_0000) + Self.uint64LE(5) + [0, 0, 0, 0, 0]
        let block = ClickHouseBlock(
            rowCount: 2, columnCount: 1,
            columnNames: ["values"],
            columnTypes: ["Array(UInt8)"],
            bodyStart: 0, bodyLength: body.count
        )
        #expect(Self.parseStage(block: block, body: body) == "decoder.array")
    }

    private static func parseStage(block: ClickHouseBlock, body: [UInt8]) -> String {
        do {
            _ = try body.withUnsafeBytes { raw in
                try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
            }
            return "none"
        } catch {
            if let typed = error as? ClickHouseError, case .protocolError(let stage, _) = typed { return stage }
            return "other: \(error)"
        }
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
