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

// Snapshot of the connection pool's runtime state, intended for
// observability dashboards, alerts, and pressure monitoring. All
// fields reflect the values at the moment `client.poolStats()` was
// called; subsequent acquire/release activity will change them.
public struct ClickHouseConnectionPoolStats: Sendable, Equatable {

    // Connections sitting idle, eligible for the next acquire without
    // opening a new socket.
    public let idleCount: Int

    // Connections currently leased out to a caller. The pool's
    // hard cap is `configuredMaxConnections`.
    public let activeCount: Int

    // Acquirers waiting because the pool is at `maxConnections`.
    // Persistent non-zero values indicate the pool is undersized for
    // the workload.
    public let waiterCount: Int

    // Lifetime count of connections successfully opened by this pool.
    // Watch the rate of change against business-as-usual: a sudden
    // spike means existing connections aren't being reused (e.g. they
    // are being torn down due to errors or the idle timeout is too
    // aggressive).
    public let totalConnectionsOpened: Int

    // Endpoints currently in failure cooldown. When > 0 the pool is
    // still routable through the remaining endpoints, but capacity is
    // reduced and tail latency may rise.
    public let unhealthyEndpointCount: Int

    // Configured caps mirrored here so a single snapshot fully
    // describes the pool's saturation.
    public let configuredMaxConnections: Int
    public let configuredMaxIdleConnections: Int

    // Per-endpoint health, in the order the endpoints were configured.
    // The entries' `status` aligns with `unhealthyEndpointCount`: the
    // count is the size of the subset where `status == .coolingDown`.
    public let endpointHealth: [ClickHouseEndpointHealth]

    public init(
        idleCount: Int,
        activeCount: Int,
        waiterCount: Int,
        totalConnectionsOpened: Int,
        unhealthyEndpointCount: Int,
        configuredMaxConnections: Int,
        configuredMaxIdleConnections: Int,
        endpointHealth: [ClickHouseEndpointHealth] = []
    ) {
        self.idleCount = idleCount
        self.activeCount = activeCount
        self.waiterCount = waiterCount
        self.totalConnectionsOpened = totalConnectionsOpened
        self.unhealthyEndpointCount = unhealthyEndpointCount
        self.configuredMaxConnections = configuredMaxConnections
        self.configuredMaxIdleConnections = configuredMaxIdleConnections
        self.endpointHealth = endpointHealth
    }

}
