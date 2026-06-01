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

/// Entry point to the DXPostgres client.
///
/// `Postgres` is a namespace, not a value you hold onto. It hands you a
/// ``PostgresClient`` — the object that carries every operation. Call
/// `Postgres.connect(…)` once, then call methods on the client it returns.
///
/// DXPostgres speaks the PostgreSQL v3 frontend/backend protocol directly, so the
/// same client connects to PostgreSQL and to any wire-compatible server —
/// YugabyteDB YSQL (port 5433), CockroachDB, and managed variants among them.
///
/// ## Long-lived application client
///
/// Open once at startup, hold it for the process lifetime, and share the one
/// instance across every request handler. ``PostgresClient`` is `Sendable` and
/// backed by a connection pool, so concurrent callers are safe on a single shared
/// instance. It conforms to ServiceLifecycle's `Service`, so it can run inside a
/// `ServiceGroup` and tear the pool down on graceful shutdown.
///
/// ```swift
/// let postgres = try await Postgres.connect(configuration)
/// let result = try await postgres.query("SELECT id, name FROM accounts WHERE active")
/// for row in result.rows {
///     let id = try row.decode(Int.self, named: "id")
///     let name = try row.decode(String.self, named: "name")
/// }
/// ```
///
/// ## Parameterized queries
///
/// Bind values positionally as `$1`, `$2`, …; they run over the extended protocol
/// and are never spliced into the SQL text:
///
/// ```swift
/// let result = try await postgres.query(
///     "SELECT name FROM accounts WHERE id = $1 AND active = $2",
///     binding: [accountID, true]
/// )
/// ```
///
/// ## Scoped usage (scripts, tests, one-off tools)
///
/// Connects, runs the body, then shuts the client down whether the body returns
/// or throws.
///
/// ```swift
/// try await Postgres.withClient(configuration) { postgres in
///     try await postgres.query("INSERT INTO audit (event) VALUES ($1)", binding: ["startup"])
/// }
/// ```
///
/// ## Ambient access
///
/// Bind one client for a scope with ``withCurrent(_:_:)``, then read it back with
/// ``current()`` from code deep in the call tree that was never handed the client.
/// Reading outside any binding throws ``PostgresError/noCurrentClient`` rather
/// than returning a null or trapping.
public enum Postgres {

    enum Ambient: Sendable {

        case unbound
        case bound(PostgresClient)
    }

    @TaskLocal static var ambient: Ambient = .unbound

    /// Opens a long-lived client and warms one connection so the first query does
    /// not pay connection setup. Hold the returned client for the application
    /// lifetime; call ``PostgresClient/shutdown()``, or run it as a
    /// ServiceLifecycle `Service`, to release the pool.
    public static func connect(_ configuration: PostgresConfiguration) async throws(PostgresError) -> PostgresClient {
        let client = PostgresClient(configuration: configuration)
        do {
            try await client.warmUp(connections: 1)
            return client
        } catch {
            await client.shutdown()
            throw error
        }
    }

    /// Connects, runs `body` with the client, then shuts the client down whether
    /// `body` returns or throws. For scripts, tests, and one-off tools — not the
    /// per-request path of a long-running service.
    public static func withClient<Result>(_ configuration: PostgresConfiguration, _ body: (PostgresClient) async throws -> Result) async throws -> Result {
        let client = try await connect(configuration)
        do {
            let result = try await body(client)
            await client.shutdown()
            return result
        } catch {
            await client.shutdown()
            throw error
        }
    }

    /// Binds `client` as the ambient client for the duration of `body`. Code in
    /// the same structured-task tree reads it back with ``current()``. The binding
    /// propagates to child tasks and task groups but not across `Task.detached`.
    public static func withCurrent<Result>(_ client: PostgresClient, _ body: () async throws -> Result) async rethrows -> Result {
        try await $ambient.withValue(.bound(client)) {
            try await body()
        }
    }

    /// Returns the ambient client bound by an enclosing ``withCurrent(_:_:)``.
    /// Throws ``PostgresError/noCurrentClient`` when no client is bound in the
    /// current task tree.
    public static func current() throws(PostgresError) -> PostgresClient {
        guard case .bound(let client) = ambient else {
            throw PostgresError.noCurrentClient
        }
        return client
    }
}
