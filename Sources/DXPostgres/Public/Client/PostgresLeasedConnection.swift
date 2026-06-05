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

/// A connection leased to a caller for the duration of a ``PostgresLeasePool``
/// `withConnection` closure. Its methods are synchronous and run on the leased
/// connection's own dedicated thread, so a run of queries inside one lease costs
/// no per-query async hand-off — the lease pays one hand-off and then proceeds at
/// the speed of the synchronous core. The handle is valid only inside the closure
/// and must not be stored or shared; it is deliberately not `Sendable`.
struct PostgresLeasedConnection {

    private let connection: BlockingPostgresConnection

    init(connection: BlockingPostgresConnection) {
        self.connection = connection
    }

    func execute(_ sql: String) throws(PostgresError) -> PostgresResult {
        try connection.execute(sql)
    }

    @discardableResult
    func execute(_ sql: String, onRow: (PostgresRowView) throws(PostgresError) -> Void) throws(PostgresError) -> [PostgresColumn] {
        try connection.execute(sql, onRow: onRow)
    }

    func query(_ statement: PostgresStatement) throws(PostgresError) -> PostgresResult {
        try connection.query(statement.sql, bindings: statement.bindings)
    }

    func query<T: Decodable>(_ statement: PostgresStatement, as type: T.Type) throws(PostgresError) -> [T] {
        try connection.query(statement.sql, bindings: statement.bindings).decode(as: type)
    }

    @discardableResult
    func query(_ statement: PostgresStatement, onRow: (PostgresRowView) throws(PostgresError) -> Void) throws(PostgresError) -> [PostgresColumn] {
        try connection.query(statement.sql, bindings: statement.bindings, onRow: onRow)
    }

    func queryScalarInt64(_ sql: String, value: Int64) throws(PostgresError) -> Int64 {
        try connection.queryScalarInt64Inline(sql, value: value)
    }
}
