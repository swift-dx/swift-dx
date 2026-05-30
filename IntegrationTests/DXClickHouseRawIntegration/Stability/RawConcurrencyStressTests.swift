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

// 100 concurrent Tasks fan out against a single shared
// RawClickHouseConnectionPool (16 connections) and run a random mix of
// SELECT/INSERT operations for the configured duration (5 min default,
// 15 min via CH_STABILITY_FULL=1).
//
// Invariants:
//
//   1. Zero errors across the run.
//   2. Final server-side row count equals the sum of every task's
//      acknowledged inserts. Per-task ranges are disjoint so the
//      assertion catches both lost writes and torn batches.
//   3. After every task returns and the post-run verification queries
//      drain, the pool's stats report `inUseConnections == 0` and
//      `idleConnections == 16` (the configured ceiling): no leaked
//      acquires, no closed connections, no pending waiters.
//   4. Zero deadlocks. The run has to complete inside its own
//      duration plus a small drain budget; the test harness's own
//      timeout will fire long before that, but the row-count match
//      is the primary deadlock detector.
extension Stability {

@Suite(
    "DXClickHouseRaw stability — concurrency stress (100 Tasks × shared 16-conn pool)",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct RawConcurrencyStressTests {

    private static let perTaskIdSpan: UInt64 = 1_000_000_000
    private static let perTaskInsertBatchRows = 50
    private static let perTaskSelectLimit = 200
    private static let seedRows = 10_000

    @Test("100 Tasks over a shared 16-connection pool record zero errors, zero leaks, matching row counts")
    func testHundredTasksOverSharedPoolNoLeaks() async throws {
        let maxConnections = RawStabilitySupport.concurrencyPoolMaxConnections
        let taskCount = RawStabilitySupport.concurrencyStressTaskCount
        let pool = try await RawStabilitySupport.makePool(
            maxConnections: maxConnections,
            minConnections: 1,
            acquireTimeout: .seconds(30)
        )
        defer { Task { await pool.close() } }

        let table = RawStabilitySupport.uniqueTable(prefix: "conc")
        try await pool.withConnection { connection in
            try await connection.sendQuery("DROP TABLE IF EXISTS \(table)")
            _ = try await connection.drainBlocks()
            try await connection.sendQuery("""
                CREATE TABLE \(table) (
                    id UInt64,
                    bucket String,
                    value Float64
                ) ENGINE = MergeTree ORDER BY id
                """)
            _ = try await connection.drainBlocks()
        }
        defer {
            Task {
                try? await pool.withConnection { connection in
                    try await connection.sendQuery("DROP TABLE IF EXISTS \(table)")
                    _ = try await connection.drainBlocks()
                }
            }
        }

        try await Self.seedFixture(pool: pool, table: table)

        let durationSeconds = RawStabilitySupport.concurrencyStressDurationSeconds
        let deadline = ContinuousClock.now.advanced(by: .seconds(durationSeconds))

        let outcomes = await withTaskGroup(of: ConcurrencyTaskOutcome.self, returning: [ConcurrencyTaskOutcome].self) { taskGroup in
            for taskIndex in 0..<taskCount {
                taskGroup.addTask {
                    await Self.runOneTask(
                        taskIndex: taskIndex,
                        pool: pool,
                        table: table,
                        deadline: deadline
                    )
                }
            }
            var collected: [ConcurrencyTaskOutcome] = []
            collected.reserveCapacity(taskCount)
            for await outcome in taskGroup {
                collected.append(outcome)
            }
            return collected
        }

        let totalErrors = outcomes.reduce(0) { $0 + $1.errorCount }
        let totalInsertedRows = outcomes.reduce(0) { $0 + $1.insertedRowCount }
        let totalSelectInvocations = outcomes.reduce(0) { $0 + $1.selectInvocations }

        #expect(totalErrors == 0, "concurrency stress surfaced \(totalErrors) errors across \(outcomes.count) tasks")
        #expect(
            totalInsertedRows > 0 || totalSelectInvocations > 0,
            "no operations completed; the test did not exercise the pool"
        )

        let serverInsertedCount = try await pool.withConnection { connection in
            try await connection.sendQuery("""
                SELECT toUInt64(count()) FROM \(table)
                WHERE id >= \(Self.perTaskIdSpan)
                """)
            return try await connection.receiveScalarUInt64()
        }
        #expect(
            serverInsertedCount == UInt64(totalInsertedRows),
            "server-side inserted row count (\(serverInsertedCount)) disagrees with task-acknowledged total (\(totalInsertedRows))"
        )

        for outcome in outcomes where outcome.insertedRowCount > 0 {
            let perTaskCount = try await pool.withConnection { connection in
                try await connection.sendQuery("""
                    SELECT toUInt64(count()) FROM \(table)
                    WHERE id >= \(outcome.idLowerBound) AND id < \(outcome.idUpperBound)
                    """)
                return try await connection.receiveScalarUInt64()
            }
            #expect(
                perTaskCount == UInt64(outcome.insertedRowCount),
                "task \(outcome.taskIndex) inserted \(outcome.insertedRowCount) rows; server reports \(perTaskCount) in [\(outcome.idLowerBound), \(outcome.idUpperBound))"
            )
        }

        let stats = await pool.stats()
        #expect(stats.inUseConnections == 0, "pool inUseConnections=\(stats.inUseConnections); an acquire leaked")
        #expect(stats.waiters == 0, "pool waiters=\(stats.waiters); a waiter leaked")
        #expect(stats.idleConnections == maxConnections, "pool idleConnections=\(stats.idleConnections), expected \(maxConnections); connections were closed under contention")
        #expect(
            stats.leasesGranted == stats.leasesReleased,
            "pool lease accounting drift: granted=\(stats.leasesGranted), released=\(stats.leasesReleased)"
        )
    }

    private static func seedFixture(pool: RawClickHouseConnectionPool, table: String) async throws {
        try await pool.withConnection { connection in
            var insertSQL = "INSERT INTO \(table) (id, bucket, value) VALUES "
            insertSQL.reserveCapacity(seedRows * 32)
            for index in 0..<seedRows {
                if index > 0 { insertSQL.append(",") }
                insertSQL.append("(\(index),'seed-\(index % 16)',\(Double(index) * 0.5))")
            }
            try await connection.sendQuery(insertSQL)
            _ = try await connection.drainBlocks()
        }
    }

    private static func runOneTask(
        taskIndex: Int,
        pool: RawClickHouseConnectionPool,
        table: String,
        deadline: ContinuousClock.Instant
    ) async -> ConcurrencyTaskOutcome {
        var random = RawStabilityRandom(seed: UInt64(taskIndex + 1) &* 2_654_435_761)
        let idBase = UInt64(taskIndex + 1) * perTaskIdSpan
        var insertedRowCount = 0
        var selectInvocations = 0
        var errorCount = 0
        var nextInsertOffset: UInt64 = 0

        while ContinuousClock.now < deadline {
            let roll = UInt8(random.next() & 0xFF)
            let chooseInsert = roll < 64
            if chooseInsert {
                let base = idBase + nextInsertOffset
                nextInsertOffset += UInt64(perTaskInsertBatchRows)
                var insertSQL = "INSERT INTO \(table) (id, bucket, value) VALUES "
                insertSQL.reserveCapacity(perTaskInsertBatchRows * 32)
                for offset in 0..<perTaskInsertBatchRows {
                    if offset > 0 { insertSQL.append(",") }
                    let identifier = base + UInt64(offset)
                    insertSQL.append("(\(identifier),'t\(taskIndex)-\(offset % 32)',\(Double(offset) * 0.25))")
                }
                do {
                    try await pool.withConnection { connection in
                        try await connection.sendQuery(insertSQL)
                        _ = try await connection.drainBlocks()
                    }
                    insertedRowCount += perTaskInsertBatchRows
                } catch {
                    errorCount += 1
                }
            } else {
                let mode = roll & 0x03
                do {
                    switch mode {
                    case 0:
                        try await pool.withConnection { connection in
                            try await connection.sendQuery("SELECT toUInt64(count()) FROM \(table) WHERE id < \(perTaskIdSpan)")
                            _ = try await connection.receiveScalarUInt64()
                        }
                    case 1:
                        try await pool.withConnection { connection in
                            try await connection.sendQuery("SELECT id, bucket, value FROM \(table) WHERE id < \(perTaskSelectLimit) ORDER BY id LIMIT \(perTaskSelectLimit)")
                            _ = try await connection.drainBlocks()
                        }
                    default:
                        try await pool.withConnection { connection in
                            try await connection.sendQuery("SELECT bucket FROM \(table) WHERE id < \(perTaskSelectLimit) LIMIT \(perTaskSelectLimit)")
                            _ = try await connection.extractStringsDrain()
                        }
                    }
                    selectInvocations += 1
                } catch {
                    errorCount += 1
                }
            }
        }

        return ConcurrencyTaskOutcome(
            taskIndex: taskIndex,
            insertedRowCount: insertedRowCount,
            selectInvocations: selectInvocations,
            errorCount: errorCount,
            idLowerBound: idBase,
            idUpperBound: idBase + nextInsertOffset
        )
    }
}

}

private struct ConcurrencyTaskOutcome: Sendable {

    let taskIndex: Int
    let insertedRowCount: Int
    let selectInvocations: Int
    let errorCount: Int
    let idLowerBound: UInt64
    let idUpperBound: UInt64
}
