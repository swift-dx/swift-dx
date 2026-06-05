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

/// A single PostgreSQL connection whose query runs synchronously on the calling
/// thread: the caller itself issues the write and blocks on the read, exactly as
/// the reference C client does. There is no worker thread and no task handoff, so
/// a query costs only the two socket syscalls and the network round-trip — none
/// of the cross-thread `futex` wakes the async pool pays to keep its caller
/// non-blocking. The trade is that the calling thread is blocked for the round
/// trip, so this path is for strictly-serial, latency-critical callers (a CLI, a
/// bounded worker, a benchmark) rather than a high-fan-out server, where
/// ``PostgresBlockingPool`` keeps the caller free instead.
///
/// `@unchecked Sendable` is sound because the underlying connection is only ever
/// driven by one caller at a time; this type performs no internal synchronization
/// and must not be shared across concurrent callers.
public final class PostgresDirectConnection: @unchecked Sendable {

    private let connection: BlockingPostgresConnection

    private init(connection: BlockingPostgresConnection) {
        self.connection = connection
    }

    public static func connect(host: String, port: Int, username: String, password: String, database: String, applicationName: String) throws(PostgresError) -> PostgresDirectConnection {
        PostgresDirectConnection(connection: try BlockingPostgresConnection.connect(host: host, port: port, username: username, password: password, database: database, applicationName: applicationName))
    }

    public func execute(_ sql: String) throws(PostgresError) -> PostgresResult {
        try connection.execute(sql)
    }

    @discardableResult
    public func execute(_ sql: String, onRow: (PostgresRowView) throws(PostgresError) -> Void) throws(PostgresError) -> [PostgresColumn] {
        try connection.execute(sql, onRow: onRow)
    }

    public func queryScalarInt64Inline(_ sql: String, value: Int64) throws(PostgresError) -> Int64 {
        try connection.queryScalarInt64Inline(sql, value: value)
    }

    public func queryScalarInt64Pipelined(_ sql: String, values: [Int64]) throws(PostgresError) -> [Int64] {
        try connection.queryScalarInt64Pipelined(sql, values: values)
    }

    public func close() {
        connection.close()
    }
}
