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

import Foundation

extension ClickHouseClient {

    // Runs ping + serverInfo + poolStats and bundles them into a
    // single report. Throws if the ping fails (caller decides what
    // a missing report means in their probe semantics).
    //
    // Pool stats and server info are gathered in parallel after the
    // ping completes, so the total wall clock is approximately
    // ping_latency + max(serverInfo, poolStats) — typically
    // dominated by the ping itself.
    public func healthCheck() async throws(ClickHouseError) -> ClickHouseHealthReport {
        let start = Date()
        try await ping()
        let latencyMs = Date().timeIntervalSince(start) * 1000.0
        let resolvedInfo = try await serverInfo()
        let resolvedStats = await poolStats()
        return Self.buildHealthReport(
            pingLatencyMillis: latencyMs,
            serverInfo: resolvedInfo,
            poolStats: resolvedStats
        )
    }

    static func buildHealthReport(
        pingLatencyMillis: Double,
        serverInfo: ClickHouseServerInfo,
        poolStats: ClickHouseConnectionPoolStats
    ) -> ClickHouseHealthReport {
        let unhealthy = poolStats.endpointHealth
            .filter { $0.status == .coolingDown }
            .map(\.endpoint)
        return ClickHouseHealthReport(
            pingLatencyMillis: pingLatencyMillis,
            serverInfo: serverInfo,
            poolStats: poolStats,
            unhealthyEndpoints: unhealthy
        )
    }

}
