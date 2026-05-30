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

// Long-lived Redis client backed by a pool of pipelining connections. One
// instance per (server, credentials, database) is the intended pattern; reuse
// it across the service lifetime rather than constructing one per request.
// `Sendable` is compiler-derived: every stored property is itself Sendable and
// all mutable state lives behind the connection pool actor.
//
// The client conforms to ServiceLifecycle's `Service` (see RedisClient+Service)
// so it can run inside a `ServiceGroup`; `run()` awaits graceful shutdown and
// then tears the pool down. The `deinit` fires a best-effort shutdown for
// callers that drop the client without calling `shutdown()` explicitly.
public final class RedisClient: Sendable {

    let pool: RedisConnectionPool
    let defaultDatabase: RedisDatabaseIndex
    let maxConnections: Int
    let resilience: RedisResilience
    let logger: Logger

    init(poolConfiguration: RedisConnectionPool.Configuration, defaultDatabase: RedisDatabaseIndex, maxConnections: Int, resilience: RedisResilience, logger: Logger) {
        self.pool = RedisConnectionPool(configuration: poolConfiguration)
        self.defaultDatabase = defaultDatabase
        self.maxConnections = maxConnections
        self.resilience = resilience
        self.logger = logger
    }

    public convenience init(configuration: RedisConfiguration) {
        self.init(
            poolConfiguration: configuration.poolConfiguration,
            defaultDatabase: configuration.database,
            maxConnections: configuration.maxConnections,
            resilience: configuration.resilience,
            logger: configuration.logger
        )
    }

    public func warmUp(connections: Int) async throws(RedisError) {
        try await RedisError.bridge {
            try await self.warmConnections(count: min(max(1, connections), self.maxConnections))
        }
    }

    public func ping() async throws(RedisError) {
        _ = try await send(.ping())
    }

    public func poolStats() async -> RedisPoolStats {
        await pool.stats()
    }

    public func shutdown() async {
        await pool.shutdown()
    }

    private func warmConnections(count: Int) async throws {
        var opened: [RedisConnection] = []
        opened.reserveCapacity(count)
        do {
            try await openInto(&opened, count: count)
        } catch {
            await releaseAll(opened)
            throw error
        }
        await releaseAll(opened)
    }

    private func openInto(_ opened: inout [RedisConnection], count: Int) async throws {
        for _ in 0..<count {
            opened.append(try await pool.acquire())
        }
    }

    private func releaseAll(_ connections: [RedisConnection]) async {
        for connection in connections {
            await pool.release(connection)
        }
    }

    deinit {
        let pool = self.pool
        Task { await pool.shutdown() }
    }
}
