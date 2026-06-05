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

/// A transaction in progress, handed to the closure of ``PostgresClient/transaction(_:)``
/// or ``Postgres/transaction(_:)``. Run statements on it the same way you would on
/// the client; they all execute on one connection, in order, inside a single
/// `BEGIN`/`COMMIT`. Returning from the closure commits; throwing rolls back. There
/// is no connection to manage and nothing to release — the handle is valid only
/// inside the closure and is deliberately not `Sendable`, so it cannot escape.
public struct PostgresTransaction {

    private let lease: PostgresLeasedConnection

    init(lease: PostgresLeasedConnection) {
        self.lease = lease
    }

    public func execute(_ sql: String) throws(PostgresError) -> PostgresResult {
        try lease.execute(sql)
    }

    @discardableResult
    public func execute(_ sql: String, onRow: (PostgresRowView) throws(PostgresError) -> Void) throws(PostgresError) -> [PostgresColumn] {
        try lease.execute(sql, onRow: onRow)
    }

    public func query(_ statement: PostgresStatement) throws(PostgresError) -> PostgresResult {
        try lease.query(statement)
    }

    public func query<T: Decodable>(_ statement: PostgresStatement, as type: T.Type) throws(PostgresError) -> [T] {
        try lease.query(statement, as: type)
    }

    @discardableResult
    public func query(_ statement: PostgresStatement, onRow: (PostgresRowView) throws(PostgresError) -> Void) throws(PostgresError) -> [PostgresColumn] {
        try lease.query(statement, onRow: onRow)
    }

    public func queryScalarInt64(_ sql: String, value: Int64) throws(PostgresError) -> Int64 {
        try lease.queryScalarInt64(sql, value: value)
    }
}
