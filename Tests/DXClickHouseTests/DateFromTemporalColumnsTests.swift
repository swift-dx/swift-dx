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
import Foundation
import Testing

// A Swift Date field is the natural target for every temporal column, not
// just DateTime. DateTime64(N) (sub-second event timestamps, the most
// common high-resolution time column), Date, and Date32 all denote an
// absolute instant, so a `let ts: Date` field must decode from them
// directly instead of forcing the ClickHouseDateTime64 / ClickHouseDate
// wrappers. Nullable wrappers are unwrapped through the null mask.
@Suite("a Swift Date decodes from every temporal ClickHouse column")
struct DateFromTemporalColumnsTests {

    private struct Row: Decodable {
        let ts: Date
    }

    private struct OptionalRow: Decodable {
        let ts: Date?
    }

    @Test("DateTime64 decodes to a Date with sub-second precision")
    func dateTime64ToDate() throws {
        let column = ClickHouseNamedColumn(name: "ts", column: .dateTime64([1_700_000_000_123], precision: 3))
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: [column], rowCount: 1)
        #expect(rows[0].ts == Date(timeIntervalSince1970: Double(1_700_000_000_123) / 1000.0))
    }

    @Test("Date (days) decodes to the midnight-UTC instant")
    func dateToDate() throws {
        let column = ClickHouseNamedColumn(name: "ts", column: .date([20_000]))
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: [column], rowCount: 1)
        #expect(rows[0].ts == Date(timeIntervalSince1970: Double(20_000) * 86_400))
    }

    @Test("Date32 (signed days) decodes, including before the epoch")
    func date32ToDate() throws {
        let column = ClickHouseNamedColumn(name: "ts", column: .date32([-100]))
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: [column], rowCount: 1)
        #expect(rows[0].ts == Date(timeIntervalSince1970: Double(-100) * 86_400))
    }

    @Test("a Nullable(DateTime64) reads present and absent rows")
    func nullableDateTime64() throws {
        let inner = ClickHouseTypedColumn.dateTime64([1_000, 0], precision: 3)
        let column = ClickHouseNamedColumn(name: "ts", column: .nullable(mask: [false, true], inner: inner))
        let rows = try ClickHouseCodableDecoder.decodeRows(type: OptionalRow.self, columns: [column], rowCount: 2)
        #expect(rows[0].ts == Date(timeIntervalSince1970: 1.0))
        #expect(rows[1].ts == nil)
    }
}
