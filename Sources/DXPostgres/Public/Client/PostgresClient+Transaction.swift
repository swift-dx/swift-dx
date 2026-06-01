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

extension PostgresClient {

    /// Runs `body` inside a single transaction on one pooled connection: issues
    /// `BEGIN`, then `COMMIT` if `body` returns, or `ROLLBACK` if it throws (the
    /// thrown error is re-raised). Run every statement through the supplied
    /// ``PostgresTransaction`` so it lands on the transaction's connection; using
    /// the client directly would run on a different connection outside the
    /// transaction. Wrapping a batch of writes this way commits once rather than
    /// once per statement, and makes the batch atomic.
    ///
    /// ```swift
    /// try await postgres.withTransaction { tx in
    ///     for record in records {
    ///         try await tx.query("INSERT INTO events (id, body) VALUES ($1, $2)", binding: [record.id, record.body])
    ///     }
    /// }
    /// ```
    public func withTransaction<Result: Sendable>(_ body: @Sendable (PostgresTransaction) async throws -> Result) async throws -> Result {
        try await pool.withConnection { connection in
            try await Self.runTransaction(on: connection, body)
        }
    }

    private static func runTransaction<Result: Sendable>(on connection: PostgresConnection, _ body: @Sendable (PostgresTransaction) async throws -> Result) async throws -> Result {
        _ = try await connection.simpleQuery("BEGIN")
        do {
            let result = try await body(PostgresTransaction(connection: connection))
            _ = try await connection.simpleQuery("COMMIT")
            return result
        } catch {
            _ = try? await connection.simpleQuery("ROLLBACK")
            throw error
        }
    }
}
