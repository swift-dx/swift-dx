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

// A batch INSERT whose FIRST row carries nil in a shaped-wrapper Optional
// field (Decimal, FixedString, Enum, DateTime64, Time64, Interval) must still
// register the column. These wrappers carry their precision / length /
// mapping in the VALUE, so a leading nil cannot type the column on its own —
// but any later row that provides a value carries the full type. The encoder
// defers the leading NULLs and backfills them once a present row defines the
// column, so the common "first event has no amount yet" shape does not force
// the caller to reorder rows. A column that is nil on EVERY row stays an
// error: its ClickHouse type genuinely cannot be inferred.
@Suite("a first-row nil shaped wrapper defers and backfills the Nullable column")
struct NilFirstShapedWrapperInsertTests {

    private struct DecimalRow: Codable, Sendable, Equatable {
        let amount: ClickHouseDecimal?
    }

    private struct FixedRow: Codable, Sendable, Equatable {
        let code: ClickHouseFixedString?
    }

    @Test("a leading nil Decimal registers Nullable(Decimal) and round-trips")
    func leadingNilDecimal() throws {
        let rows = [
            DecimalRow(amount: nil),
            DecimalRow(amount: ClickHouseDecimal(unscaled: 150, precision: 10, scale: 2)),
        ]
        let columns = try ClickHouseRowEncoder().encode(rows)
        #expect(columns[0].column.typeName == "Nullable(Decimal(10, 2))")
        #expect(columns[0].column.rowCount == 2)
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: DecimalRow.self, columns: columns, rowCount: rows.count)
        #expect(decoded == rows)
    }

    @Test("a leading nil FixedString registers Nullable(FixedString) and round-trips")
    func leadingNilFixedString() throws {
        let rows = [
            FixedRow(code: nil),
            FixedRow(code: ClickHouseFixedString(bytes: Array("abcd".utf8), length: 4)),
            FixedRow(code: nil),
        ]
        let columns = try ClickHouseRowEncoder().encode(rows)
        #expect(columns[0].column.typeName == "Nullable(FixedString(4))")
        #expect(columns[0].column.rowCount == 3)
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: FixedRow.self, columns: columns, rowCount: rows.count)
        #expect(decoded == rows)
    }

    @Test("a Decimal column that is nil on every row is still rejected") 
    func allNilDecimalThrows() throws {
        var thrown = false
        do {
            _ = try ClickHouseRowEncoder().encode([DecimalRow(amount: nil), DecimalRow(amount: nil)])
        } catch {
            thrown = true
        }
        #expect(thrown)
    }
}
