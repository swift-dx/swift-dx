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
/// ``Postgres/connect(host:port:username:password:database:applicationName:poolSize:)``,
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

    /// Releases every pooled connection. Call once when the client is no longer
    /// needed; in-flight statements should complete first.
    func shutdown()
}

extension PostgresClient {

    /// Runs a parameterized statement and decodes every row into `type`.
    public func query<T: Decodable & Sendable>(_ statement: PostgresStatement, as type: T.Type) async throws(PostgresError) -> [T] {
        try await query(statement).decode(as: type)
    }
}
