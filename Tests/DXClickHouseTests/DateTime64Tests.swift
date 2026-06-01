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

@Suite("DXClickHouse DateTime64 column")
struct ClickHouseDateTime64Tests {

    struct Row: Codable, Sendable, Equatable {
        let ts: ClickHouseDateTime64
    }

    @Test("encoder produces a DateTime64(9) column carrying the ticks and precision")
    func encodesDateTime64Column() throws {
        let columns = try ClickHouseRowEncoder().encode([
            Row(ts: ClickHouseDateTime64(ticks: 5_000_000_000, precision: 9)),
            Row(ts: ClickHouseDateTime64(ticks: -1, precision: 9)),
        ])
        #expect(columns.count == 1)
        #expect(columns[0].name == "ts")
        #expect(columns[0].column.typeName == "DateTime64(9)")
        switch columns[0].column {
        case .dateTime64(let ticks, let precision):
            #expect(ticks == [5_000_000_000, -1])
            #expect(precision == 9)
        default:
            Issue.record("expected a dateTime64 column, got \(columns[0].column.typeName)")
        }
    }

    @Test("block writer emits each tick as 8 little-endian bytes")
    func blockBytesAreLittleEndianInt64() throws {
        let columns = try ClickHouseRowEncoder().encode([
            Row(ts: ClickHouseDateTime64(ticks: 5_000_000_000, precision: 9)),
        ])
        let packet = try ClickHouseBlockWriter.encodeDataPacket(
            columns: columns,
            revision: ClickHouseBlockWriter.revisionWithCustomSerialization
        )
        var expected: [UInt8] = []
        withUnsafeBytes(of: Int64(5_000_000_000).littleEndian) { expected.append(contentsOf: $0) }
        #expect(Self.contains(packet, expected))
    }

    @Test("decode reconstructs the wrapper with the column precision and ticks")
    func decodeRoundTrip() throws {
        let columns: [ClickHouseNamedColumn] = [
            ClickHouseNamedColumn(name: "ts", column: .dateTime64([5_000_000_000, -1], precision: 9)),
        ]
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 2)
        #expect(rows == [
            Row(ts: ClickHouseDateTime64(ticks: 5_000_000_000, precision: 9)),
            Row(ts: ClickHouseDateTime64(ticks: -1, precision: 9)),
        ])
    }

    @Test("Date convenience derives ticks at the requested precision and round-trips")
    func dateConvenience() {
        let value = ClickHouseDateTime64(Date(timeIntervalSince1970: 1.5), precision: 3)
        #expect(value.ticks == 1500)
        #expect(value.precision == 3)
        #expect(ClickHouseDateTime64(ticks: 1500, precision: 3).date.timeIntervalSince1970 == 1.5)
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }
}
