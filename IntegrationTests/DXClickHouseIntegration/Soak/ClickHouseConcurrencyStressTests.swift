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
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing

// Concurrency-stress suite. 100 tasks fan out against a shared
// ClickHouseClient and run a random mix of SELECTs and INSERTs for the
// configured duration (30s default, 300s "full" via
// CH_CONCURRENCY_STRESS_SECONDS=300). Each task picks an operation by
// seeded RNG so the run is reproducible.
//
// Invariants:
//
//   1. Zero errors across the run.
//   2. Final inserted-row count equals the sum of every task's
//      acknowledged inserts (no torn writes, no lost batches).
//   3. Final SELECT against every per-task id range returns the
//      same row count the task acknowledged (no incorrect results).
//   4. Pool waiter count is zero at completion (no leaked acquires).
//
// The seed table for SELECTs is pre-populated before the fan-out so
// every task has the same fixture surface — concurrent INSERTs land
// in a separate per-task scratch range whose ids cannot collide with
// the seed range.
@Suite(
    "ClickHouse integration — concurrency stress (100 tasks × random SELECT/INSERT mix)",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct ClickHouseConcurrencyStressTests {

    private static let taskCount = 100
    private static let seedRows = 100_000
    private static let perTaskInsertBatchRows = 100
    private static let perTaskInsertIdSpan: UInt64 = 1_000_000_000
    private static let maxConnections = 32

    @Test("100 tasks × random SELECT/INSERT mix for the configured duration record zero errors, no deadlocks, no incorrect results")
    func hundredTaskMixHoldsCorrectnessAndLiveness() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 8)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: SoakTestSupport.makeConfiguration(
            eventLoopGroup: group,
            maxConnections: Self.maxConnections,
            endpoints: SoakTestSupport.defaultEndpoints()
        ))
        defer { Task { await client.shutdown() } }

        let table = SoakTestSupport.uniqueTable("conc")
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (id UInt64, tag String, value Float64) ENGINE = MergeTree ORDER BY id")
        defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }

        let seedIds = (0..<Self.seedRows).map { UInt64($0) }
        let seedTags = (0..<Self.seedRows).map { "seed-\($0 % 100)" }
        let seedValues = (0..<Self.seedRows).map { Double($0) * 0.5 }
        try await client.insert(into: table, columns: [
            .init(name: "id", values: .uint64(seedIds)),
            .init(name: "tag", values: .string(seedTags)),
            .init(name: "value", values: .float64(seedValues)),
        ])

        let durationSeconds = SoakTestSupport.concurrencyStressDurationSeconds
        let deadline = ContinuousClock.now.advanced(by: .seconds(durationSeconds))

        let outcomes = try await withThrowingTaskGroup(of: TaskOutcome.self, returning: [TaskOutcome].self) { taskGroup in
            for taskIndex in 0..<Self.taskCount {
                taskGroup.addTask {
                    var rng = SeededRandomNumberGenerator(seed: UInt64(taskIndex + 1) * 2_654_435_761)
                    var insertedRowCount: Int = 0
                    var selectInvocations: Int = 0
                    var errorCount: Int = 0
                    var nextInsertOffset: UInt64 = 0
                    let idBase = UInt64(taskIndex + 1) * Self.perTaskInsertIdSpan
                    while ContinuousClock.now < deadline {
                        let rollByte = UInt8.random(in: 0...255, using: &rng)
                        let pickInsert = rollByte < 64
                        if pickInsert {
                            let base = idBase + nextInsertOffset
                            nextInsertOffset += UInt64(Self.perTaskInsertBatchRows)
                            let ids = (base..<(base + UInt64(Self.perTaskInsertBatchRows))).map { $0 }
                            let tags = (0..<Self.perTaskInsertBatchRows).map { "t\(taskIndex)-\($0 % 32)" }
                            let values = (0..<Self.perTaskInsertBatchRows).map { Double($0) * 0.25 }
                            do {
                                try await client.insert(into: table, columns: [
                                    .init(name: "id", values: .uint64(ids)),
                                    .init(name: "tag", values: .string(tags)),
                                    .init(name: "value", values: .float64(values)),
                                ])
                                insertedRowCount += Self.perTaskInsertBatchRows
                            } catch {
                                errorCount += 1
                            }
                        } else {
                            do {
                                // Pick a SELECT shape by RNG. Four
                                // surfaces participate equally: scalar,
                                // bulk columnar SELECT, view-path
                                // selectStringColumns, and view-path
                                // selectRowsBuilder. The view paths
                                // exercise the per-block arena lifetime
                                // and the row-builder closure under
                                // contention against the same shared
                                // client + pool.
                                let pick = rollByte & 0x03
                                switch pick {
                                case 0:
                                    let limit = Int.random(in: 100...10000, using: &rng)
                                    _ = try await client.scalarInt64("SELECT toInt64(count()) FROM \(table) WHERE id < \(limit)")
                                case 1:
                                    let blocks = client.selectColumns("SELECT id, tag, value FROM \(table) WHERE id < 5000 ORDER BY id LIMIT 2000")
                                    var seen = 0
                                    for try await block in blocks { seen += block.rowCount }
                                    _ = seen
                                case 2:
                                    let stream = client.selectStringColumns("SELECT tag FROM \(table) WHERE id < 5000 LIMIT 2000")
                                    var bytes = 0
                                    for try await block in stream {
                                        if case .present(let column) = block.stringColumn(named: "tag") {
                                            column.forEach { _, view in bytes += view.utf8Length }
                                        }
                                    }
                                    _ = bytes
                                default:
                                    let stream = client.selectRowsBuilder(
                                        ConcurrencyStressViewBuilderRow.self,
                                        from: "SELECT tag FROM \(table) WHERE id < 5000 LIMIT 2000"
                                    ) { block, rowIndex in
                                        if case .present(let column) = block.stringColumn(named: "tag") {
                                            return ConcurrencyStressViewBuilderRow(tagBytes: column.view(at: rowIndex).utf8Length)
                                        }
                                        return ConcurrencyStressViewBuilderRow(tagBytes: 0)
                                    }
                                    var totalBytes = 0
                                    for try await batch in stream {
                                        for row in batch { totalBytes += row.tagBytes }
                                    }
                                    _ = totalBytes
                                }
                                selectInvocations += 1
                            } catch {
                                errorCount += 1
                            }
                        }
                    }
                    return TaskOutcome(
                        taskIndex: taskIndex,
                        insertedRowCount: insertedRowCount,
                        selectInvocations: selectInvocations,
                        errorCount: errorCount,
                        idBase: idBase,
                        idUpperBound: idBase + nextInsertOffset
                    )
                }
            }
            var collected: [TaskOutcome] = []
            collected.reserveCapacity(Self.taskCount)
            for try await sample in taskGroup {
                collected.append(sample)
            }
            return collected
        }

        let totalErrors = outcomes.reduce(0) { $0 + $1.errorCount }
        let totalInsertedRows = outcomes.reduce(0) { $0 + $1.insertedRowCount }
        let totalSelectInvocations = outcomes.reduce(0) { $0 + $1.selectInvocations }

        #expect(totalErrors == 0, "concurrency stress surfaced \(totalErrors) errors across \(Self.taskCount) tasks")
        #expect(totalInsertedRows > 0 || totalSelectInvocations > 0, "no operations completed; the test did not exercise the client")

        let serverInsertedCount = try await client.scalarInt64("SELECT toInt64(count()) FROM \(table) WHERE id >= \(Self.perTaskInsertIdSpan)")
        #expect(
            serverInsertedCount == Int64(totalInsertedRows),
            "server-side row count (\(serverInsertedCount)) disagrees with task-acknowledged total (\(totalInsertedRows))"
        )

        for outcome in outcomes where outcome.insertedRowCount > 0 {
            let perTaskCount = try await client.scalarInt64(
                "SELECT toInt64(count()) FROM \(table) WHERE id >= \(outcome.idBase) AND id < \(outcome.idUpperBound)"
            )
            #expect(
                perTaskCount == Int64(outcome.insertedRowCount),
                "task \(outcome.taskIndex) inserted \(outcome.insertedRowCount) rows, server reports \(perTaskCount) in [\(outcome.idBase), \(outcome.idUpperBound))"
            )
        }

        let poolStats = await client.poolStats()
        #expect(poolStats.waiterCount == 0, "pool waiter count was \(poolStats.waiterCount) at completion")
        #expect(poolStats.activeCount == 0, "pool active count was \(poolStats.activeCount) at completion; an acquire leaked")
    }

}

private struct TaskOutcome: Sendable {

    let taskIndex: Int
    let insertedRowCount: Int
    let selectInvocations: Int
    let errorCount: Int
    let idBase: UInt64
    let idUpperBound: UInt64
}

private struct ConcurrencyStressViewBuilderRow: Sendable {

    let tagBytes: Int
}
