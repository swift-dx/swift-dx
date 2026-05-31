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

/// A ``SQLiteTableProvider`` backed by a fixed set of rows captured at
/// construction.
///
/// This is the simplest way to expose in-memory Swift data to SQL: give the
/// table a name, its column names, and the row values once, then query it as
/// `SELECT ... FROM <name>`. Every scan reads the same captured `rows`, so the
/// table is constant for the lifetime of the database. The column count in each
/// row should match the number of declared columns; a query selecting a column
/// index beyond a row's values reads nothing for that cell.
public struct SQLiteStaticTable: SQLiteTableProvider {

    public let name: String
    public let schema: String
    public let storedRows: [[SQLiteValue]]

    public init(name: String, columns: [String], rows: [[SQLiteValue]]) {
        self.name = name
        self.schema = "CREATE TABLE \(name)(\(columns.joined(separator: ", ")))"
        self.storedRows = rows
    }

    public func rows() -> [[SQLiteValue]] {
        storedRows
    }
}
