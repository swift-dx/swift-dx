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

// Holds the SELECT result columns indexed by name and validates that
// every column shares the same row count. The decoder reads a single
// row by indexing each column's typed array at `rowIndex`.
//
// Validation happens once at construction (instead of per-row or
// per-field), so a malformed result set fails loudly before any
// rows are constructed.
final class ClickHouseRowDecoderStorage {

    private enum RowCountWitness {

        case unset
        case observed(Int)

    }

    let columnsByName: [String: ClickHouseColumnEntry.Values]
    let columnOrder: [String]
    let rowCount: Int

    init(columns: [ClickHouseSelectColumn]) throws {
        var byName: [String: ClickHouseColumnEntry.Values] = [:]
        var order: [String] = []
        var observedRowCount: RowCountWitness = .unset
        for column in columns {
            try Self.appendColumn(column: column, byName: &byName, order: &order, observedRowCount: &observedRowCount)
        }
        self.columnsByName = byName
        self.columnOrder = order
        switch observedRowCount {
        case .observed(let value): self.rowCount = value
        case .unset: self.rowCount = 0
        }
    }

    private static func appendColumn(
        column: ClickHouseSelectColumn,
        byName: inout [String: ClickHouseColumnEntry.Values],
        order: inout [String],
        observedRowCount: inout RowCountWitness
    ) throws {
        let count = column.values.rowCount
        try requireConsistentRowCount(column: column, count: count, observedRowCount: &observedRowCount)
        byName[column.name] = column.values
        order.append(column.name)
    }

    private static func requireConsistentRowCount(
        column: ClickHouseSelectColumn,
        count: Int,
        observedRowCount: inout RowCountWitness
    ) throws {
        switch observedRowCount {
        case .unset:
            observedRowCount = .observed(count)
        case .observed(let expected):
            if count != expected {
                throw ClickHouseError.rowDecoderMismatchedColumnRowCounts(
                    columnName: column.name, expected: expected, actual: count
                )
            }
        }
    }

}
