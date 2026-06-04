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

import Logging
import NIOCore

/// Long-lived PostgreSQL client backed by a pool of connections. One instance
/// per (server, role, database) is the intended pattern; hold it for the process
/// lifetime and share it across request handlers rather than constructing one per
/// request. `Sendable` is compiler-derived: every stored property is itself
/// Sendable and all mutable state lives behind the connection pool actor.
///
/// The client conforms to ServiceLifecycle's `Service` (see PostgresClient+Service)
/// so it can run inside a `ServiceGroup`; `run()` warms a connection, parks until
/// graceful shutdown, then tears the pool down. The `deinit` fires a best-effort
/// shutdown for callers that drop the client without calling `shutdown()`.
public final class PostgresClient: Sendable {

    let pool: PostgresConnectionPool
    let maxConnections: Int
    let requestTimeout: TimeAmount
    let resilience: PostgresResilience
    let observability: PostgresObservability

    var logger: Logger {
        observability.logger.logger
    }

    init(poolConfiguration: PostgresConnectionPool.Configuration, maxConnections: Int, requestTimeout: TimeAmount, resilience: PostgresResilience, observability: PostgresObservability) {
        self.pool = PostgresConnectionPool(configuration: poolConfiguration)
        self.maxConnections = maxConnections
        self.requestTimeout = requestTimeout
        self.resilience = resilience
        self.observability = observability
    }

    public convenience init(configuration: PostgresConfiguration) {
        let observability = PostgresObservability(logger: configuration.logger)
        self.init(poolConfiguration: configuration.poolConfiguration(observability: observability), maxConnections: configuration.maxConnections, requestTimeout: configuration.requestTimeout, resilience: configuration.resilience, observability: observability)
    }

    /// Opens up to `connections` pooled connections so the first queries do not
    /// pay connection setup. The count is clamped to at least one and at most the
    /// configured `maxConnections`.
    public func warmUp(connections: Int) async throws(PostgresError) {
        try await PostgresError.bridge {
            try await self.warmConnections(count: min(max(1, connections), self.maxConnections))
        }
    }

    /// Runs `SELECT 1` to confirm the server is reachable and answering.
    public func ping() async throws(PostgresError) {
        _ = try await query("SELECT 1")
    }

    public func poolStats() async -> PostgresPoolStats {
        pool.stats()
    }

    /// A cumulative snapshot of query, error, retry, pool-timeout, and
    /// connection-open counters since this client was created. Sample it
    /// periodically and difference successive snapshots to derive rates.
    public func metrics() -> PostgresClientMetrics {
        observability.metrics.snapshot()
    }

    /// Closes every pooled connection. After shutdown the client rejects further
    /// operations with ``PostgresError/poolShutdown``.
    public func shutdown() async {
        await pool.shutdown()
    }

    private func warmConnections(count: Int) async throws {
        var opened: [PostgresConnection] = []
        opened.reserveCapacity(count)
        do {
            try await openInto(&opened, count: count)
        } catch {
            await releaseAll(opened)
            throw error
        }
        await releaseAll(opened)
    }

    private func openInto(_ opened: inout [PostgresConnection], count: Int) async throws {
        for _ in 0..<count {
            opened.append(try await pool.acquire())
        }
    }

    private func releaseAll(_ connections: [PostgresConnection]) async {
        for connection in connections {
            pool.release(connection)
        }
    }

    deinit {
        let pool = self.pool
        Task { await pool.shutdown() }
    }
}
