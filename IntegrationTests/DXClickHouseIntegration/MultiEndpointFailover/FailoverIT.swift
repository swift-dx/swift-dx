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

// The pool's failover contract: when a new connection has to be opened
// and the first endpoint refuses the connect, the pool transparently
// tries the next endpoint without the caller observing a typed error.
// Drives that path by registering a dead endpoint up front and asserts
// the very first `withConnection` lease succeeds via the live endpoint
// while the stats counter records the failover.
@Suite(
    "DXClickHouse MultiEndpointFailover: dead endpoint causes silent failover",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct FailoverIT {

    @Test("fresh pool with dead endpoint first opens via the live endpoint and stats record the failover")
    func freshLeaseAfterDeadEndpointSucceeds() async throws {
        let live = MultiEndpointFailoverSupport.liveEndpoint
        let dead = MultiEndpointFailoverSupport.unreachableEndpoint
        let configuration = ClickHouseConnectionPool.Configuration(
            endpoints: [dead, live],
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

        let value = try await pool.withConnection { connection in
            try await connection.sendQuery("SELECT toUInt64(7)")
            return try await connection.receiveScalarUInt64()
        }
        #expect(value == 7)
        let stats = await pool.stats()
        #expect(stats.endpointFailovers >= 1)
    }

    @Test("once an endpoint goes dead between leases, the next acquire still succeeds via the next endpoint")
    func failoverBetweenLeases() async throws {
        let live = MultiEndpointFailoverSupport.liveEndpoint
        let dead = MultiEndpointFailoverSupport.unreachableEndpoint
        // Two reachable entries up front; on the third lease the cursor
        // lands on the dead entry, which the pool must skip onto the
        // live one without surfacing a typed error to the caller.
        let configuration = ClickHouseConnectionPool.Configuration(
            endpoints: [live, live, dead],
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

        // Force three concurrent fresh opens by holding all leases at
        // the same time. The pool must hand back exactly three distinct
        // working connections, and the dead endpoint must surface as a
        // failover counter rather than a caller-visible error.
        try await withThrowingTaskGroup(of: UInt64.self) { group in
            for index in 0..<3 {
                group.addTask {
                    try await pool.withConnection { connection in
                        try await connection.sendQuery("SELECT toUInt64(\(index + 1))")
                        return try await connection.receiveScalarUInt64()
                    }
                }
            }
            var sum: UInt64 = 0
            for try await value in group { sum += value }
            #expect(sum == 6)
        }
        let stats = await pool.stats()
        #expect(stats.endpointFailovers >= 1)
        #expect(stats.acquireTimeouts == 0)
    }

    @Test("five sequential leases with one dead endpoint never surface a typed error to the caller")
    func sequentialLeasesNeverSurfaceFailureToCaller() async throws {
        let live = MultiEndpointFailoverSupport.liveEndpoint
        let dead = MultiEndpointFailoverSupport.unreachableEndpoint
        let configuration = ClickHouseConnectionPool.Configuration(
            endpoints: [dead, live],
            user: MultiEndpointFailoverSupport.user,
            password: MultiEndpointFailoverSupport.password,
            database: MultiEndpointFailoverSupport.database,
            minConnections: 0,
            maxConnections: 1,
            acquireTimeout: .seconds(5),
            preflightPing: false,
            evictionInterval: .seconds(60)
        )
        let pool = try await ClickHouseConnectionPool(configuration: configuration)
        defer { Task { await pool.close() } }
        for iteration in 1...5 {
            let value = try await pool.withConnection { connection in
                try await connection.sendQuery("SELECT toUInt64(\(iteration))")
                return try await connection.receiveScalarUInt64()
            }
            #expect(value == UInt64(iteration))
        }
        let stats = await pool.stats()
        #expect(stats.acquireTimeouts == 0)
    }
}
