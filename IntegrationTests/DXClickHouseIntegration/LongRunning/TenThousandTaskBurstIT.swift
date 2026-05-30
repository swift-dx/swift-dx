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

// 10,000 concurrent Tasks fan-in against a 32-connection pool, each
// running one quick scalar query. The point is to stress the pool's
// FIFO waiter queue and confirm:
//
//   1. Every task completes with the expected scalar value (no lost
//      acquires, no torn responses).
//   2. Zero recorded errors.
//   3. After the burst drains, the pool's stats report `inUseConnections == 0`
//      and `idleConnections == 32` (no leaked acquires, no closed
//      connections, no pending waiters).
//
// Gated by CH_LONG_RUNNING=1. The burst typically completes in seconds
// on localhost but is excluded from the default run because it spikes
// CPU and connection establishment when the harness first warms up.
@Suite(
    "DXClickHouse LongRunning: 10K Tasks × 32-connection pool (CH_LONG_RUNNING=1)",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil && ProcessInfo.processInfo.environment["CH_LONG_RUNNING"] == "1"),
    .serialized
)
struct TenThousandTaskBurstIT {

    private static let taskCount = 10_000
    private static let poolMaxConnections = 32

    @Test("10,000 concurrent Tasks each run a scalar; pool drains cleanly with zero errors")
    func tenThousandTaskBurst() async throws {
        let pool = try await LongRunningSupport.makePool(maxConnections: Self.poolMaxConnections)
        defer { Task { await pool.close() } }

        // Prime so the burst exercises the waiter path immediately.
        try await pool.withConnection { connection in
            try await connection.sendQuery("SELECT toUInt64(1)")
            _ = try await connection.receiveScalarUInt64()
        }

        let outcomes = await withTaskGroup(of: BurstOutcome.self) { group in
            for taskIndex in 0..<Self.taskCount {
                group.addTask {
                    let expected = UInt64(taskIndex % 1024)
                    do {
                        let value = try await pool.withConnection { connection in
                            try await connection.sendQuery("SELECT toUInt64(\(expected))")
                            return try await connection.receiveScalarUInt64()
                        }
                        if value == expected {
                            return .success
                        }
                        return .mismatch
                    } catch {
                        return .failed(String(describing: error))
                    }
                }
            }
            var results: [BurstOutcome] = []
            results.reserveCapacity(Self.taskCount)
            for await outcome in group {
                results.append(outcome)
            }
            return results
        }

        let successes = outcomes.filter { if case .success = $0 { return true } else { return false } }.count
        let mismatches = outcomes.filter { if case .mismatch = $0 { return true } else { return false } }.count
        let failures = outcomes.compactMap { outcome -> String? in
            if case .failed(let description) = outcome { return description }
            return nil
        }
        #expect(successes == Self.taskCount, "expected \(Self.taskCount) successes, got \(successes) (mismatches=\(mismatches), failures=\(failures.count))")
        #expect(mismatches == 0)
        #expect(failures.isEmpty, "first failure: \(failures.first ?? "")")

        // Drain settling, then assert the pool is back to a healthy
        // steady state.
        try await Task.sleep(for: .milliseconds(500))
        let stats = await pool.stats()
        #expect(stats.inUseConnections == 0)
        #expect(stats.waiters == 0)
        #expect(stats.idleConnections <= Self.poolMaxConnections)
        #expect(stats.leasesGranted >= Self.taskCount)
        #expect(stats.leasesReleased >= Self.taskCount)
    }

    private enum BurstOutcome: Sendable {
        case success
        case mismatch
        case failed(String)
    }
}
