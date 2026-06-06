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

/// The client a consumer holds to talk to PostgreSQL. Obtain one from
/// ``Postgres/connect(host:port:username:password:database:applicationName:poolSize:maxSubscriptions:)``,
/// share the single instance across concurrent callers, and call ``shutdown()``
/// once at the end of its life. It is backed by a pool of connections, so each
/// ``execute(_:)`` borrows a connection, runs the statement, and returns it.
public protocol PostgresClient: Sendable {

    /// Submits a statement and returns the result: the column descriptions paired
    /// with the rows, each field being its raw wire bytes or SQL NULL.
    func execute(_ sql: String) async throws(PostgresError) -> PostgresResult

    /// Submits a parameterized statement whose interpolated values were bound, not
    /// spliced, and returns the result.
    func query(_ statement: PostgresStatement) async throws(PostgresError) -> PostgresResult

    /// Runs `body` as a single transaction: every statement on the handed-in
    /// ``PostgresTransaction`` executes on one connection, in order, between a
    /// `BEGIN` and a `COMMIT`. Returning commits; throwing rolls back and rethrows
    /// the thrown error. There is no connection to manage.
    func transaction<Result: Sendable>(_ body: @escaping @Sendable (PostgresTransaction) throws -> Result) async throws -> Result

    /// Releases every pooled connection. Call once when the client is no longer
    /// needed; in-flight statements should complete first.
    func shutdown()
}

extension PostgresClient {

    /// Runs a parameterized statement and decodes every row into `type`.
    public func query<T: Decodable & Sendable>(_ statement: PostgresStatement, as type: T.Type) async throws(PostgresError) -> [T] {
        try await query(statement).decode(as: type)
    }

    /// Publishes `payload` on `channel` so every session subscribed to it through
    /// ``PostgresListener`` receives the notification. Both arguments are bound as
    /// parameters to `pg_notify`, never spliced into SQL, and the call runs on a
    /// pooled connection — publishing needs no dedicated connection. Delivery is
    /// ephemeral and at-most-once: a notification reaches only the sessions
    /// listening at the moment it is sent.
    public func notify(channel: String, payload: String) async throws(PostgresError) {
        _ = try await query("SELECT pg_notify(\(channel), \(payload))")
    }
}
