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

@Suite("DXClickHouse Date Time Time64 columns")
struct ClickHouseDateTimeColumnTests {

    struct Row: Codable, Sendable, Equatable {
        let day: ClickHouseDate
        let clock: ClickHouseTime
        let precise: ClickHouseTime64
    }

    @Test("encoder produces Date, Time, and Time64 columns with matching type names")
    func encodesColumns() throws {
        let columns = try ClickHouseRowEncoder().encode([
            Row(
                day: ClickHouseDate(days: 20_000),
                clock: ClickHouseTime(seconds: -3661),
                precise: ClickHouseTime64(ticks: 5_000_000_000, precision: 9)
            ),
        ])
        #expect(columns.count == 3)
        #expect(columns[0].column.typeName == "Date")
        #expect(columns[1].column.typeName == "Time")
        #expect(columns[2].column.typeName == "Time64(9)")
        switch columns[0].column {
        case .date(let values): #expect(values == [20_000])
        default: Issue.record("expected date column")
        }
        switch columns[1].column {
        case .time(let values): #expect(values == [-3661])
        default: Issue.record("expected time column")
        }
        switch columns[2].column {
        case .time64(let ticks, let precision):
            #expect(ticks == [5_000_000_000])
            #expect(precision == 9)
        default: Issue.record("expected time64 column")
        }
    }

    @Test("block writer emits Date as 2 LE bytes, Time as 4, Time64 as 8")
    func blockBytesAreLittleEndian() throws {
        let columns = try ClickHouseRowEncoder().encode([
            Row(
                day: ClickHouseDate(days: 0x1234),
                clock: ClickHouseTime(seconds: -3661),
                precise: ClickHouseTime64(ticks: 5_000_000_000, precision: 9)
            ),
        ])
        let packet = try ClickHouseBlockWriter.encodeDataPacket(
            columns: columns,
            revision: ClickHouseBlockWriter.revisionWithCustomSerialization
        )
        var dateBytes: [UInt8] = []
        withUnsafeBytes(of: UInt16(0x1234).littleEndian) { dateBytes.append(contentsOf: $0) }
        var timeBytes: [UInt8] = []
        withUnsafeBytes(of: Int32(-3661).littleEndian) { timeBytes.append(contentsOf: $0) }
        var time64Bytes: [UInt8] = []
        withUnsafeBytes(of: Int64(5_000_000_000).littleEndian) { time64Bytes.append(contentsOf: $0) }
        #expect(Self.contains(packet, dateBytes))
        #expect(Self.contains(packet, timeBytes))
        #expect(Self.contains(packet, time64Bytes))
    }

    @Test("decode reconstructs Date, Time, and Time64 wrappers")
    func decodeRoundTrip() throws {
        let columns: [ClickHouseNamedColumn] = [
            ClickHouseNamedColumn(name: "day", column: .date([20_000, 0])),
            ClickHouseNamedColumn(name: "clock", column: .time([-3661, 86_399])),
            ClickHouseNamedColumn(name: "precise", column: .time64([5_000_000_000, -1], precision: 9)),
        ]
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 2)
        #expect(rows == [
            Row(
                day: ClickHouseDate(days: 20_000),
                clock: ClickHouseTime(seconds: -3661),
                precise: ClickHouseTime64(ticks: 5_000_000_000, precision: 9)
            ),
            Row(
                day: ClickHouseDate(days: 0),
                clock: ClickHouseTime(seconds: 86_399),
                precise: ClickHouseTime64(ticks: -1, precision: 9)
            ),
        ])
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }
}
