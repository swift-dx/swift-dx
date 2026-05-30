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

import DXClickHouse
import Foundation
import Testing

// Connection-pool acquire / release latency. Measures the round-trip
// cost of `withConnection { ... }` against a warm pool that already has
// at least one idle connection. The work inside the closure is a noop
// (immediate return), so each iteration captures only the acquire +
// release path, plus the actor hops.
//
// PRODUCTION-3WAY-BENCH.md does not capture this directly. Localhost
// pool hops sit well under 1 ms; the baseline is 2 ms to give the
// regression check headroom for run-to-run jitter on shared CI runners.
@Suite(
    "DXClickHouse pool acquire performance",
    .enabled(if: ClickHousePerformanceHarness.isEnabled)
)
struct PoolAcquirePerformanceTests {

    @Test("warm-pool acquire/release median stays under baseline * 1.2")
    func warmPoolAcquireRelease() async throws {
        let configuration = ClickHouseConnectionPool.Configuration(
            host: ClickHousePerformanceHarness.host,
            port: ClickHousePerformanceHarness.port,
            user: ClickHousePerformanceHarness.user,
            password: ClickHousePerformanceHarness.password,
            database: ClickHousePerformanceHarness.database,
            minConnections: 2,
            maxConnections: 4,
            acquireTimeout: .seconds(5),
            preflightPing: false,
            evictionInterval: .seconds(3600)
        )
        let pool = try await ClickHouseConnectionPool(configuration: configuration)
        // Prime the pool so the first measured iteration acquires an
        // already-warm connection rather than paying first-touch open cost.
        _ = try await pool.withConnection { _ in 0 }
        try await ClickHousePerformanceHarness.measureRepeated(
            mode: "pool_acquire_warm",
            iterations: 500,
            warmupIterations: 10,
            baselineMedianMs: ClickHousePerformanceBaselines.scaled(
                ClickHousePerformanceBaselines.poolAcquireWarmMs
            )
        ) {
            let value = try await pool.withConnection { _ in 7 }
            #expect(value == 7)
        }
        await pool.close()
    }
}
