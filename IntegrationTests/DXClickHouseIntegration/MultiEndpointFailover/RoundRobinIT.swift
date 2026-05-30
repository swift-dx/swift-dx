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

// Drives the `ClickHouseConnectionPool` against three endpoints: two
// reachable (the same live broker registered twice — production setups
// usually point at distinct hosts, but the failover algorithm only
// cares about reachability per attempt) and one synthetic unreachable
// entry at 127.0.0.1:1. Confirms that the pool round-robins across the
// reachable entries and counts the dead-endpoint skip as a failover.
@Suite(
    "DXClickHouse MultiEndpointFailover: round-robin across 3 endpoints (2 live + 1 dead)",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct RoundRobinIT {

    @Test("pool opens fresh connections by visiting every reachable endpoint and skipping the dead one")
    func roundRobinSkipsDeadEndpointAcrossOpens() async throws {
        let live = MultiEndpointFailoverSupport.liveEndpoint
        let dead = MultiEndpointFailoverSupport.unreachableEndpoint
        let configuration = ClickHouseConnectionPool.Configuration(
            endpoints: [live, dead, live],
            user: MultiEndpointFailoverSupport.user,
            password: MultiEndpointFailoverSupport.password,
            database: MultiEndpointFailoverSupport.database,
            minConnections: 0,
            maxConnections: 4,
            acquireTimeout: .seconds(5),
            preflightPing: false,
            evictionInterval: .seconds(60)
        )
        let pool = try await ClickHouseConnectionPool(configuration: configuration)
        defer { Task { await pool.close() } }

        // Each iteration forces the pool to open a fresh connection by
        // not releasing the lease until after the body returns; with
        // maxConnections=4 and an empty idle list at start, the first
        // three opens cycle through live, dead-skipped-to-live, live.
        var observed: [UInt64] = []
        try await withThrowingTaskGroup(of: UInt64.self) { group in
            for iteration in 0..<3 {
                group.addTask {
                    try await pool.withConnection { connection in
                        try await connection.sendQuery("SELECT toUInt64(\(iteration + 1))")
                        return try await connection.receiveScalarUInt64()
                    }
                }
            }
            for try await value in group {
                observed.append(value)
            }
        }
        #expect(observed.sorted() == [1, 2, 3])

        let stats = await pool.stats()
        #expect(stats.endpointFailovers >= 1)
        #expect(stats.openedTotal >= 2)
    }

    @Test("repeated leases after release reuse live connections and do not retry the dead endpoint each time")
    func reusedLeasesDoNotRetryDeadEndpoint() async throws {
        let live = MultiEndpointFailoverSupport.liveEndpoint
        let dead = MultiEndpointFailoverSupport.unreachableEndpoint
        let configuration = ClickHouseConnectionPool.Configuration(
            endpoints: [live, dead],
            user: MultiEndpointFailoverSupport.user,
            password: MultiEndpointFailoverSupport.password,
            database: MultiEndpointFailoverSupport.database,
            minConnections: 1,
            maxConnections: 2,
            acquireTimeout: .seconds(5),
            preflightPing: false,
            evictionInterval: .seconds(60)
        )
        let pool = try await ClickHouseConnectionPool(configuration: configuration)
        defer { Task { await pool.close() } }
        for index in 0..<10 {
            let value = try await pool.withConnection { connection in
                try await connection.sendQuery("SELECT toUInt64(\(index + 100))")
                return try await connection.receiveScalarUInt64()
            }
            #expect(value == UInt64(index + 100))
        }
        let stats = await pool.stats()
        // We expect each acquire after the first to reuse the idle
        // connection; openedTotal therefore stays small. The dead
        // endpoint should account for failover only when fresh opens
        // happen, not on every lease.
        #expect(stats.openedTotal <= 3, "openedTotal=\(stats.openedTotal); reused idle connections should not require fresh opens per acquire")
    }

    @Test("multi-endpoint pool with the dead endpoint first still opens via failover to the live entry")
    func deadFirstStillSucceeds() async throws {
        let live = MultiEndpointFailoverSupport.liveEndpoint
        let dead = MultiEndpointFailoverSupport.unreachableEndpoint
        let configuration = ClickHouseConnectionPool.Configuration(
            endpoints: [dead, live],
            user: MultiEndpointFailoverSupport.user,
            password: MultiEndpointFailoverSupport.password,
            database: MultiEndpointFailoverSupport.database,
            minConnections: 1,
            maxConnections: 2,
            acquireTimeout: .seconds(5),
            preflightPing: false,
            evictionInterval: .seconds(60)
        )
        let pool = try await ClickHouseConnectionPool(configuration: configuration)
        defer { Task { await pool.close() } }
        let value = try await pool.withConnection { connection in
            try await connection.sendQuery("SELECT toUInt64(42)")
            return try await connection.receiveScalarUInt64()
        }
        #expect(value == 42)
        let stats = await pool.stats()
        #expect(stats.endpointFailovers >= 1)
    }
}
