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
            try await Self.runTransaction(on: connection, setup: [], body)
        }
    }

    /// Runs `body` inside a single transaction whose `COMMIT` is held to the given
    /// ``PostgresDurability``. The level is applied with `SET LOCAL
    /// synchronous_commit` after `BEGIN`, so it governs only this transaction and
    /// reverts when it ends; the pooled connection carries no durability state into
    /// the next caller. Use ``synchronous`` for writes that must survive a crash
    /// and ``asynchronous`` for high-volume, loss-tolerant writes; in both cases the
    /// transaction commits only on real server confirmation, or throws.
    public func withTransaction<Result: Sendable>(durability: PostgresDurability, _ body: @Sendable (PostgresTransaction) async throws -> Result) async throws -> Result {
        try await pool.withConnection { connection in
            try await Self.runTransaction(on: connection, setup: ["SET LOCAL synchronous_commit = \(durability.synchronousCommitValue)"], body)
        }
    }

    /// Runs one statement at the given durability, wrapping it in a transaction so
    /// `SET LOCAL synchronous_commit` applies. This is the single-write counterpart
    /// to ``withTransaction(durability:_:)``: the statement commits only when the
    /// server confirms it to the chosen level, or throws.
    public func execute(_ sql: String, durability: PostgresDurability) async throws(PostgresError) -> PostgresQueryResult {
        try await PostgresError.bridge {
            try await self.withTransaction(durability: durability) { transaction in
                try await transaction.query(sql)
            }
        }
    }

    public func execute(_ sql: String, binding parameters: [any PostgresEncodable], durability: PostgresDurability) async throws(PostgresError) -> PostgresQueryResult {
        try await PostgresError.bridge {
            try await self.withTransaction(durability: durability) { transaction in
                try await transaction.query(sql, binding: parameters)
            }
        }
    }

    private static func runTransaction<Result: Sendable>(on connection: PostgresConnection, setup: [String], _ body: @Sendable (PostgresTransaction) async throws -> Result) async throws -> Result {
        _ = try await connection.simpleQuery("BEGIN")
        do {
            for statement in setup {
                _ = try await connection.simpleQuery(statement)
            }
            let result = try await body(PostgresTransaction(connection: connection))
            _ = try await connection.simpleQuery("COMMIT")
            return result
        } catch {
            _ = try? await connection.simpleQuery("ROLLBACK")
            throw error
        }
    }
}
