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

@testable import DXClickHouse
import Foundation
import Testing

@Suite("ClickHouseHealthReport — composition from ping/serverInfo/poolStats")
struct ClickHouseHealthReportTests {

    private static let sampleServerInfo = ClickHouseServerInfo(
        name: "ClickHouse",
        version: "24.8.1",
        timezone: "UTC",
        displayName: "test-shard-1",
        revision: 54_478
    )

    private static func stats(
        endpointHealth: [ClickHouseEndpointHealth] = []
    ) -> ClickHouseConnectionPoolStats {
        ClickHouseConnectionPoolStats(
            idleCount: 1,
            activeCount: 2,
            waiterCount: 0,
            totalConnectionsOpened: 5,
            unhealthyEndpointCount: endpointHealth.filter { $0.status == .coolingDown }.count,
            configuredMaxConnections: 10,
            configuredMaxIdleConnections: 5,
            endpointHealth: endpointHealth
        )
    }

    @Test("buildHealthReport packages all three inputs verbatim into the report")
    func buildHealthReportPackagesAllInputs() {
        let stats = Self.stats()
        let report = ClickHouseClient.buildHealthReport(
            pingLatencyMillis: 12.5,
            serverInfo: Self.sampleServerInfo,
            poolStats: stats
        )
        #expect(report.pingLatencyMillis == 12.5)
        #expect(report.serverInfo == Self.sampleServerInfo)
        #expect(report.poolStats == stats)
    }

    @Test("a fully-healthy pool produces an empty unhealthyEndpoints array")
    func healthyPoolHasNoUnhealthyEndpoints() {
        let stats = Self.stats(endpointHealth: [
            .init(endpoint: .init(host: "h1", port: 9000), status: .healthy),
            .init(endpoint: .init(host: "h2", port: 9000), status: .healthy)
        ])
        let report = ClickHouseClient.buildHealthReport(
            pingLatencyMillis: 1.0,
            serverInfo: Self.sampleServerInfo,
            poolStats: stats
        )
        #expect(report.unhealthyEndpoints.isEmpty)
    }

    @Test("the unhealthyEndpoints array contains exactly the endpoints reporting .coolingDown")
    func unhealthyEndpointsArrayMatchesPoolHealth() {
        let stats = Self.stats(endpointHealth: [
            .init(endpoint: .init(host: "ok", port: 9000), status: .healthy),
            .init(endpoint: .init(host: "broken1", port: 9000), status: .coolingDown),
            .init(endpoint: .init(host: "broken2", port: 9000), status: .coolingDown)
        ])
        let report = ClickHouseClient.buildHealthReport(
            pingLatencyMillis: 5.0,
            serverInfo: Self.sampleServerInfo,
            poolStats: stats
        )
        #expect(report.unhealthyEndpoints.map(\.host) == ["broken1", "broken2"])
        #expect(report.unhealthyEndpoints.count == report.poolStats.unhealthyEndpointCount)
    }

    @Test("the unhealthyEndpoints array preserves the configured ordering of endpoints in the pool stats")
    func unhealthyEndpointsPreserveOrdering() {
        let stats = Self.stats(endpointHealth: [
            .init(endpoint: .init(host: "first", port: 9000), status: .coolingDown),
            .init(endpoint: .init(host: "second", port: 9000), status: .healthy),
            .init(endpoint: .init(host: "third", port: 9000), status: .coolingDown)
        ])
        let report = ClickHouseClient.buildHealthReport(
            pingLatencyMillis: 0.5,
            serverInfo: Self.sampleServerInfo,
            poolStats: stats
        )
        #expect(report.unhealthyEndpoints.map(\.host) == ["first", "third"])
    }

    @Test("ClickHouseHealthReport is Equatable — two snapshots with same inputs compare equal")
    func reportIsEquatable() {
        let stats = Self.stats()
        let a = ClickHouseClient.buildHealthReport(pingLatencyMillis: 5.0, serverInfo: Self.sampleServerInfo, poolStats: stats)
        let b = ClickHouseClient.buildHealthReport(pingLatencyMillis: 5.0, serverInfo: Self.sampleServerInfo, poolStats: stats)
        let c = ClickHouseClient.buildHealthReport(pingLatencyMillis: 6.0, serverInfo: Self.sampleServerInfo, poolStats: stats)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("a high ping latency is preserved precisely (no rounding)")
    func pingLatencyPrecisionPreserved() {
        let report = ClickHouseClient.buildHealthReport(
            pingLatencyMillis: 1234.567_891,
            serverInfo: Self.sampleServerInfo,
            poolStats: Self.stats()
        )
        #expect(report.pingLatencyMillis == 1234.567_891)
    }

    @Test("unhealthyEndpoints is empty when poolStats.endpointHealth is empty (e.g. zero configured endpoints)")
    func emptyPoolHasNoUnhealthy() {
        let report = ClickHouseClient.buildHealthReport(
            pingLatencyMillis: 0.0,
            serverInfo: Self.sampleServerInfo,
            poolStats: Self.stats(endpointHealth: [])
        )
        #expect(report.unhealthyEndpoints.isEmpty)
    }

    @Test("a single failed endpoint surfaces in unhealthyEndpoints with the correct host:port")
    func singleFailedEndpoint() {
        let stats = Self.stats(endpointHealth: [
            .init(endpoint: .init(host: "primary-shard", port: 9440), status: .coolingDown)
        ])
        let report = ClickHouseClient.buildHealthReport(
            pingLatencyMillis: 100.0,
            serverInfo: Self.sampleServerInfo,
            poolStats: stats
        )
        #expect(report.unhealthyEndpoints.count == 1)
        #expect(report.unhealthyEndpoints[0].host == "primary-shard")
        #expect(report.unhealthyEndpoints[0].port == 9440)
    }

}
