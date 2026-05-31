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

/// One row mutation reported to an update hook: which operation occurred, on
/// which database and table, and the affected row's rowid.
public struct SQLiteChange: Sendable, Equatable {

    public let operation: SQLiteChangeOperation
    public let databaseName: String
    public let tableName: String
    public let rowID: Int64

    public init(operation: SQLiteChangeOperation, databaseName: String, tableName: String, rowID: Int64) {
        self.operation = operation
        self.databaseName = databaseName
        self.tableName = tableName
        self.rowID = rowID
    }
}
