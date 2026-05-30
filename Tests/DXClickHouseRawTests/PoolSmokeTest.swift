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

import DXClickHouseRaw
import Foundation
import Testing

@Suite(
    "RawClickHouseConnectionPool smoke",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct RawClickHouseConnectionPoolSmoke {

    private static var host: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
    }

    private static var port: Int {
        Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
    }

    private static var user: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default"
    }

    private static var password: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? ""
    }

    private static var database: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "default"
    }

    private static func makePool(minConnections: Int = 1, maxConnections: Int = 4) async throws -> RawClickHouseConnectionPool {
        try await RawClickHouseConnectionPool(
            host: Self.host,
            port: Self.port,
            user: Self.user,
            password: Self.password,
            database: Self.database,
            minConnections: minConnections,
            maxConnections: maxConnections
        )
    }

    @Test("withConnection returns a working connection")
    func basicAcquireRelease() async throws {
        let pool = try await Self.makePool()
        let rows = try await pool.withConnection { connection in
            try await connection.sendQuery("SELECT toUInt64(42)")
            return try await connection.receiveScalarUInt64()
        }
        #expect(rows == 42)
        let stats = await pool.stats()
        #expect(stats.inUseConnections == 0)
        #expect(stats.idleConnections >= 1)
        #expect(stats.leasesGranted == stats.leasesReleased)
        await pool.close()
    }

    @Test("Sequential 50 acquires reuse pooled connections without leak")
    func sequentialAcquireReuse() async throws {
        let pool = try await Self.makePool(minConnections: 2, maxConnections: 4)
        for iteration in 0..<50 {
            let value = try await pool.withConnection { connection in
                try await connection.sendQuery("SELECT toUInt64(\(iteration))")
                return try await connection.receiveScalarUInt64()
            }
            #expect(value == UInt64(iteration))
        }
        let stats = await pool.stats()
        #expect(stats.inUseConnections == 0)
        #expect(stats.openedTotal <= 4)
        #expect(stats.leasesGranted == 50)
        #expect(stats.leasesReleased == 50)
        await pool.close()
    }

    @Test("100 concurrent tasks on a 4-connection pool complete without leak")
    func concurrentNoLeak() async throws {
        let pool = try await Self.makePool(minConnections: 1, maxConnections: 4)
        let total: Int64 = try await withThrowingTaskGroup(of: UInt64.self) { group in
            for iteration in 0..<100 {
                let captured = iteration
                group.addTask {
                    try await pool.withConnection { connection in
                        try await connection.sendQuery("SELECT toUInt64(\(captured))")
                        return try await connection.receiveScalarUInt64()
                    }
                }
            }
            var sum: Int64 = 0
            for try await value in group {
                sum &+= Int64(value)
            }
            return sum
        }
        let expected: Int64 = (0..<100).reduce(0) { $0 + Int64($1) }
        #expect(total == expected)
        let stats = await pool.stats()
        #expect(stats.inUseConnections == 0)
        #expect(stats.waiters == 0)
        #expect(stats.leasesGranted == 100)
        #expect(stats.leasesReleased == 100)
        #expect(stats.openedTotal <= 4)
        await pool.close()
    }

    @Test("Acquire timeout fires when all connections are held")
    func acquireTimeoutFiresWhenSaturated() async throws {
        let configuration = RawClickHouseConnectionPool.Configuration(
            host: Self.host,
            port: Self.port,
            user: Self.user,
            password: Self.password,
            database: Self.database,
            minConnections: 0,
            maxConnections: 1,
            acquireTimeout: .milliseconds(150)
        )
        let pool = try await RawClickHouseConnectionPool(configuration: configuration)
        let blocker = Task {
            try await pool.withConnection { connection in
                try await connection.sendQuery("SELECT toUInt64(1)")
                _ = try await connection.receiveScalarUInt64()
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        var caught: RawClickHouseConnectionPool.Failure?
        do {
            _ = try await pool.withConnection { connection in
                try await connection.sendQuery("SELECT toUInt64(2)")
                return try await connection.receiveScalarUInt64()
            }
        } catch let failure as RawClickHouseConnectionPool.Failure {
            caught = failure
        }
        try await blocker.value
        switch caught {
        case .some(.acquireTimedOut): break
        default: Issue.record("expected acquireTimedOut, got \(String(describing: caught))")
        }
        let stats = await pool.stats()
        #expect(stats.acquireTimeouts == 1)
        #expect(stats.inUseConnections == 0)
        #expect(stats.waiters == 0)
        await pool.close()
    }

    @Test("Pool close fails subsequent acquires")
    func acquireAfterClose() async throws {
        let pool = try await Self.makePool()
        await pool.close()
        var caught: RawClickHouseConnectionPool.Failure?
        do {
            _ = try await pool.withConnection { connection in
                try await connection.sendQuery("SELECT 1")
                return try await connection.drainBlocks()
            }
        } catch let failure as RawClickHouseConnectionPool.Failure {
            caught = failure
        }
        switch caught {
        case .some(.poolClosed): break
        default: Issue.record("expected poolClosed, got \(String(describing: caught))")
        }
    }
}
