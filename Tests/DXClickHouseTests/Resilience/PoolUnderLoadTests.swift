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

// Burst-load coverage for ClickHouseConnectionPool. A fixed-size pool
// must keep its accounting consistent under heavy concurrent demand:
// every lease that's granted must be released, no waiters can be
// orphaned, and the open-total must not exceed maxConnections.
@Suite(
    "Pool under burst load: leases balance, no leaks, no orphan waiters",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHousePoolUnderLoadTests {

    private static var host: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
    }
    private static var port: Int {
        Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
    }

    private static func makePool(maxConnections: Int) async throws -> ClickHouseConnectionPool {
        try await ClickHouseConnectionPool(
            host: host,
            port: port,
            minConnections: 1,
            maxConnections: maxConnections,
            acquireTimeout: .seconds(10)
        )
    }

    @Test("100-task burst against a 16-conn pool: leases balance and no leaks")
    func hundredTaskBurst() async throws {
        let pool = try await Self.makePool(maxConnections: 16)
        defer { Task { await pool.close() } }

        let observed: UInt64 = try await withThrowingTaskGroup(of: UInt64.self) { group in
            for iteration in 0..<100 {
                let captured = iteration
                group.addTask {
                    try await pool.withConnection { connection in
                        try await connection.sendQuery("SELECT toUInt64(\(captured))")
                        return try await connection.receiveScalarUInt64()
                    }
                }
            }
            var sum: UInt64 = 0
            for try await value in group {
                sum &+= value
            }
            return sum
        }

        let expected: UInt64 = (0..<100).reduce(0) { $0 + UInt64($1) }
        #expect(observed == expected)

        let stats = await pool.stats()
        #expect(stats.leasesGranted == 100)
        #expect(stats.leasesReleased == 100)
        #expect(stats.inUseConnections == 0)
        #expect(stats.waiters == 0)
        #expect(stats.openedTotal <= 16)
    }

    @Test("Smaller pool (4 connections) handles 64 concurrent tasks with parking + recycle")
    func smallPoolHandlesParkedWaiters() async throws {
        let pool = try await Self.makePool(maxConnections: 4)
        defer { Task { await pool.close() } }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for iteration in 0..<64 {
                let captured = iteration
                group.addTask {
                    try await pool.withConnection { connection in
                        try await connection.sendQuery("SELECT toUInt64(\(captured))")
                        let value = try await connection.receiveScalarUInt64()
                        #expect(value == UInt64(captured))
                    }
                }
            }
            try await group.waitForAll()
        }

        let stats = await pool.stats()
        #expect(stats.leasesGranted == 64)
        #expect(stats.leasesReleased == 64)
        #expect(stats.inUseConnections == 0)
        #expect(stats.openedTotal <= 4)
    }

    @Test("Errors inside withConnection still release the lease")
    func errorReleasesLease() async throws {
        let pool = try await Self.makePool(maxConnections: 2)
        defer { Task { await pool.close() } }

        struct DeliberateError: Error {}
        var caught = false
        do {
            _ = try await pool.withConnection { connection in
                try await connection.sendQuery("SELECT 1")
                _ = try await connection.drainBlocks()
                throw DeliberateError()
            }
        } catch is DeliberateError {
            caught = true
        }
        #expect(caught)
        let stats = await pool.stats()
        #expect(stats.inUseConnections == 0)
        #expect(stats.leasesGranted == stats.leasesReleased)
    }

    @Test("Sequential acquire/release reuses idle entries without growing the pool")
    func sequentialReuseStaysWithinBounds() async throws {
        let pool = try await Self.makePool(maxConnections: 4)
        defer { Task { await pool.close() } }

        for iteration in 0..<50 {
            let value = try await pool.withConnection { connection in
                try await connection.sendQuery("SELECT toUInt64(\(iteration))")
                return try await connection.receiveScalarUInt64()
            }
            #expect(value == UInt64(iteration))
        }
        let stats = await pool.stats()
        #expect(stats.openedTotal <= 4)
        #expect(stats.leasesGranted == 50)
        #expect(stats.leasesReleased == 50)
    }
}
