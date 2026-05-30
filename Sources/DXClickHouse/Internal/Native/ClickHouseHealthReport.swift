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

// Snapshot of the client's health for liveness/readiness probes.
// Produced by `client.healthCheck()`; bundles a ping round-trip,
// the server's metadata as observed at connection time, and the
// current pool stats so a probe can make a decision from a single
// reading.
public struct ClickHouseHealthReport: Sendable, Equatable {

    // Round-trip latency of the ping that produced this report.
    // Comparable to historical baseline for slow-server detection.
    public let pingLatencyMillis: Double

    // Server identity as negotiated during the connection's hello
    // handshake. Same instance across all reports from the same
    // connection; safe to display in dashboards.
    public let serverInfo: ClickHouseServerInfo

    // Snapshot of the connection pool at the moment the report was
    // built. Use the `idleCount`/`activeCount`/`waiterCount` fields
    // to decide whether the pool is undersized.
    public let poolStats: ClickHouseConnectionPoolStats

    // Endpoints currently in cooldown, derived from `poolStats` for
    // probe convenience. Empty when every configured endpoint is
    // healthy.
    public let unhealthyEndpoints: [ClickHouseEndpoint]

    public init(
        pingLatencyMillis: Double,
        serverInfo: ClickHouseServerInfo,
        poolStats: ClickHouseConnectionPoolStats,
        unhealthyEndpoints: [ClickHouseEndpoint]
    ) {
        self.pingLatencyMillis = pingLatencyMillis
        self.serverInfo = serverInfo
        self.poolStats = poolStats
        self.unhealthyEndpoints = unhealthyEndpoints
    }

}
