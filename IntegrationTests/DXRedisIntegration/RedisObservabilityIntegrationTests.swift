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

import DXRedis
import Testing

// Confirms the metrics counters reflect real activity end to end against a live
// Redis: completed commands, a physical connection open, and latency all show up
// in the snapshot. (commandErrorsTotal counts resilience-boundary failures, not
// server logical-error replies, so it is exercised by the unit suite instead.)
@Suite(.enabled(if: RedisIntegration.isEnabled)) struct RedisObservabilityIntegrationTests {

    @Test func countsCommandsAndConnections() async throws {
        let client = try RedisIntegration.makeClient(maxConnections: 2)
        let key = RedisIntegration.uniquePrefix()
        try await client.ping()
        _ = try await client.send(RedisCommand("SET", key, "1"))
        _ = try await client.send(RedisCommand("GET", key))

        let metrics = client.metrics()
        #expect(metrics.commandsTotal >= 3)
        #expect(metrics.connectionsOpenedTotal >= 1)
        #expect(metrics.meanCommandDurationNanos > 0)

        let pool = await client.poolStats()
        #expect(pool.maxConnections == 2)
        #expect(pool.idleConnections + pool.inUseConnections >= 1)

        await client.shutdown()
    }
}
