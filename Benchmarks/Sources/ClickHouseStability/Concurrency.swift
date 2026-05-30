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

// Concurrency-stress phase. N tasks share one
// ClickHouseConnectionPool and pick a random one of four query
// shapes per iteration for the configured duration. Asserts at the
// end:
//
//   * zero errors across the run
//   * pool has no leaked leases, no pending waiters, no in-use slots
//   * INSERT row counts on the server equal the sum of per-task
//     acknowledged INSERTs
//
// The four shapes are:
//   * scalar SELECT count of seeded rows
//   * columnar SELECT of a small slice (uses drainBlocks for the
//     wire path; row count discarded since the raw transport does
//     not materialise typed rows here)
//   * view SELECT against the same slice via extractStringsDrain
//   * INSERT of one row per iteration into a per-run scratch table
//     using server-side VALUES (no client-side block encoder yet on
//     the raw transport).
enum StabilityConcurrency {

    private static let perTaskSeedIdSpan: UInt64 = 1_000_000_000

    static func run() async {
        print("[STAB CONC] starting duration=\(stabilityConcurrencyDuration)s tasks=\(stabilityConcurrencyTasks)")

        let pool: ClickHouseConnectionPool
        do {
            pool = try await ClickHouseConnectionPool(
                host: stabilityHost,
                port: stabilityPort,
                user: stabilityUser,
                password: stabilityPassword,
                database: stabilityDatabase,
                minConnections: 4,
                maxConnections: 32,
                acquireTimeout: .seconds(30)
            )
        } catch {
            print("[STAB CONC] FAIL pool init: \(error)")
            return
        }
        defer { Task { await pool.close() } }

        let runTag = Int(Date().timeIntervalSince1970)
        let insertTable = "\(stabilityDatabase).stab_conc_inserts"

        // Boot a single connection for the schema setup so the pool's
        // hot slots stay clean for the fan-out below.
        do {
            try await pool.withConnection { connection in
                try await connection.sendQuery("CREATE DATABASE IF NOT EXISTS \(stabilityDatabase)")
                _ = try await connection.drainBlocks()
                try await connection.sendQuery("DROP TABLE IF EXISTS \(insertTable)")
                _ = try await connection.drainBlocks()
                try await connection.sendQuery("""
                    CREATE TABLE \(insertTable) (
                        run_tag UInt64,
                        task_index UInt64,
                        row_index UInt64,
                        payload String,
                        inserted_at DateTime DEFAULT now()
                    ) ENGINE = MergeTree() ORDER BY (run_tag, task_index, row_index)
                    """)
                _ = try await connection.drainBlocks()
            }
        } catch {
            print("[STAB CONC] FAIL schema setup: \(error)")
            return
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(stabilityConcurrencyDuration))
        let runStart = ContinuousClock.now

        let outcomes = await withTaskGroup(of: TaskOutcome.self, returning: [TaskOutcome].self) { taskGroup in
            for taskIndex in 0..<stabilityConcurrencyTasks {
                taskGroup.addTask {
                    await runTask(
                        taskIndex: taskIndex,
                        pool: pool,
                        deadline: deadline,
                        runTag: runTag,
                        insertTable: insertTable
                    )
                }
            }
            var collected: [TaskOutcome] = []
            collected.reserveCapacity(stabilityConcurrencyTasks)
            for await sample in taskGroup {
                collected.append(sample)
            }
            return collected
        }
        let totalSeconds = StabilityClock.elapsedSeconds(runStart)

        let totalErrors = outcomes.reduce(0) { $0 + $1.errorCount }
        let totalScalarSelects = outcomes.reduce(0) { $0 + $1.scalarSelects }
        let totalColumnarSelects = outcomes.reduce(0) { $0 + $1.columnarSelects }
        let totalViewSelects = outcomes.reduce(0) { $0 + $1.viewSelects }
        let totalInserts = outcomes.reduce(0) { $0 + $1.insertedRows }
        let totalOperations = totalScalarSelects + totalColumnarSelects + totalViewSelects + totalInserts

        // Per-task INSERT counts must match the server's row count
        // for that task's range.
        var rowCountMismatch = 0
        var rowCountQueries = 0
        do {
            try await pool.withConnection { connection in
                for outcome in outcomes where outcome.insertedRows > 0 {
                    try await connection.sendQuery("""
                        SELECT toInt64(count()) FROM \(insertTable)
                        WHERE run_tag = \(runTag) AND task_index = \(outcome.taskIndex)
                        """)
                    let actual = try await connection.receiveScalarUInt64()
                    rowCountQueries += 1
                    if Int(actual) != outcome.insertedRows {
                        print("[STAB CONC] mismatch task=\(outcome.taskIndex) expected=\(outcome.insertedRows) server=\(actual)")
                        rowCountMismatch += 1
                    }
                }
                try await connection.sendQuery("SELECT toInt64(count()) FROM \(insertTable) WHERE run_tag = \(runTag)")
                let totalOnServer = try await connection.receiveScalarUInt64()
                print("[STAB CONC] server total_inserts=\(totalOnServer) task_ack_total=\(totalInserts)")
                if Int(totalOnServer) != totalInserts {
                    rowCountMismatch += 1
                }
            }
        } catch {
            print("[STAB CONC] FAIL post-run verification: \(error)")
            rowCountMismatch += 1
        }

        let poolStats = await pool.stats()
        let leaseLeak = poolStats.leasesGranted - poolStats.leasesReleased
        let totalThroughput = totalSeconds > 0 ? Double(totalOperations) / totalSeconds : 0
        let insertThroughput = totalSeconds > 0 ? Double(totalInserts) / totalSeconds : 0
        let selectThroughput = totalSeconds > 0 ? Double(totalScalarSelects + totalColumnarSelects + totalViewSelects) / totalSeconds : 0

        print("[STAB CONC] summary tasks=\(stabilityConcurrencyTasks) duration=\(Int(totalSeconds))s total_ops=\(totalOperations) total_errors=\(totalErrors)")
        print("[STAB CONC] breakdown scalar_selects=\(totalScalarSelects) columnar_selects=\(totalColumnarSelects) view_selects=\(totalViewSelects) inserts=\(totalInserts)")
        print("[STAB CONC] throughput overall=\(String(format: "%.1f", totalThroughput))/s selects=\(String(format: "%.1f", selectThroughput))/s inserts=\(String(format: "%.1f", insertThroughput))/s")
        print("[STAB CONC] pool_stats idle=\(poolStats.idleConnections) in_use=\(poolStats.inUseConnections) waiters=\(poolStats.waiters) opened_total=\(poolStats.openedTotal) leases_granted=\(poolStats.leasesGranted) leases_released=\(poolStats.leasesReleased) acquire_timeouts=\(poolStats.acquireTimeouts) lease_leak=\(leaseLeak)")
        print("[STAB CONC] verification queries=\(rowCountQueries) mismatches=\(rowCountMismatch)")

        let passed =
            totalErrors == 0 &&
            leaseLeak == 0 &&
            poolStats.waiters == 0 &&
            poolStats.inUseConnections == 0 &&
            poolStats.acquireTimeouts == 0 &&
            rowCountMismatch == 0
        print("[STAB CONC] verdict zero_errors=\(totalErrors == 0) zero_lease_leak=\(leaseLeak == 0) zero_waiters=\(poolStats.waiters == 0) zero_in_use=\(poolStats.inUseConnections == 0) zero_acquire_timeouts=\(poolStats.acquireTimeouts == 0) row_count_match=\(rowCountMismatch == 0)")
        print("[STAB CONC] result=\(passed ? "PASS" : "FAIL")")

        // Cleanup so repeated runs don't grow the test database.
        do {
            try await pool.withConnection { connection in
                try await connection.sendQuery("DROP TABLE IF EXISTS \(insertTable)")
                _ = try await connection.drainBlocks()
            }
        } catch {
            print("[STAB CONC] cleanup failed: \(error)")
        }
    }

    private struct TaskOutcome: Sendable {

        let taskIndex: Int
        let insertedRows: Int
        let scalarSelects: Int
        let columnarSelects: Int
        let viewSelects: Int
        let errorCount: Int
    }

    private static func runTask(
        taskIndex: Int,
        pool: ClickHouseConnectionPool,
        deadline: ContinuousClock.Instant,
        runTag: Int,
        insertTable: String
    ) async -> TaskOutcome {
        var rng = StabilityRNG(seed: UInt64(taskIndex + 1) &* 2_654_435_761)
        var insertedRows = 0
        var scalarSelects = 0
        var columnarSelects = 0
        var viewSelects = 0
        var errorCount = 0
        while ContinuousClock.now < deadline {
            let roll = UInt8(rng.next() & 0xFF)
            let pick = roll & 0x03
            do {
                switch pick {
                case 0:
                    try await pool.withConnection { connection in
                        try await connection.sendQuery("SELECT toInt64(count()) FROM \(stabilityLedgerTable) WHERE entity_id = '\(StabilityIdentifiers.aggregateId(Int(rng.next() % UInt64(stabilityLedgerUniqueIds))))'")
                        _ = try await connection.receiveScalarUInt64()
                    }
                    scalarSelects += 1
                case 1:
                    try await pool.withConnection { connection in
                        try await connection.sendQuery("SELECT entity_id, created_at FROM \(stabilityLedgerTable) WHERE entity_kind = '\(StabilityIdentifiers.aggregateKind(Int(rng.next() % UInt64(stabilityLedgerKinds))))' ORDER BY created_at DESC LIMIT 200")
                        _ = try await connection.drainBlocks()
                    }
                    columnarSelects += 1
                case 2:
                    try await pool.withConnection { connection in
                        try await connection.sendQuery("SELECT entity_id FROM \(stabilityLedgerTable) WHERE entity_kind = '\(StabilityIdentifiers.aggregateKind(Int(rng.next() % UInt64(stabilityLedgerKinds))))' LIMIT 200")
                        _ = try await connection.extractStringsDrain()
                    }
                    viewSelects += 1
                default:
                    let rowIndex = insertedRows
                    try await pool.withConnection { connection in
                        try await connection.sendQuery("INSERT INTO \(insertTable) (run_tag, task_index, row_index, payload) VALUES (\(runTag), \(taskIndex), \(rowIndex), 'conc-payload')")
                        _ = try await connection.drainBlocks()
                    }
                    insertedRows += 1
                }
            } catch {
                errorCount += 1
                // Bail out fast if the upstream is wedged; ten errors in
                // a row from one task means something terminal happened
                // and continuing would just inflate the error count.
                if errorCount > 10 {
                    break
                }
            }
        }
        return TaskOutcome(
            taskIndex: taskIndex,
            insertedRows: insertedRows,
            scalarSelects: scalarSelects,
            columnarSelects: columnarSelects,
            viewSelects: viewSelects,
            errorCount: errorCount
        )
    }
}
