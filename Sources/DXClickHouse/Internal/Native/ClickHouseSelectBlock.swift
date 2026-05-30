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

// One Data block returned by a SELECT, in column-major form. The
// server splits a result set into multiple blocks; iterators over
// `selectColumns` yield one of these per Data packet on the wire.
// `rowCount == 0` blocks carry the schema only and are emitted at
// the start of every SELECT — consumers that materialize rows must
// skip them.
public struct ClickHouseSelectBlock: Sendable {

    public let rowCount: Int
    public let columns: [ClickHouseSelectColumn]

    public init(rowCount: Int, columns: [ClickHouseSelectColumn]) {
        self.rowCount = rowCount
        self.columns = columns
    }

    // Look up a column by name. Returns the typed lookup outcome; the
    // caller switches over the cases to distinguish "present" from
    // "absent". The cyclomatic-complexity rule kept this body small;
    // callers that want a typed throw can use `requireColumn(named:)`.
    public func column(named: String) -> ClickHouseSelectColumnLookup {
        if let match = columns.first(where: { $0.name == named }) {
            return .present(match)
        }
        return .absent
    }

    // Throwing variant for callers that treat absence as a hard
    // failure. Throws `unsupportedSelectColumnType` with the requested
    // name embedded so the consumer can see which column was missing.
    public func requireColumn(named: String) throws(ClickHouseError) -> ClickHouseSelectColumn {
        switch column(named: named) {
        case .present(let column): return column
        case .absent:
            throw ClickHouseError.unsupportedSelectColumnType(typeName: "missing column \(named)")
        }
    }

}
