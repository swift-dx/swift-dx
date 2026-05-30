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

// Connection-pool benchmark binary. Drives the
// ClickHouseConnectionPool with N concurrent tasks against a
// bounded-size pool of AsyncClickHouseConnection workers, and
// reports throughput + latency percentiles.
//
// Modes:
//
//   concurrent_select_raw_pool   N tasks × random SELECT point-lookup
//                                against bench_ledgers.ledger_NM.
//   concurrent_insert_raw_pool   N tasks × INSERT INTO test.pool_insert
//                                VALUES (...) — server-side insert,
//                                no client-side block encoding (raw
//                                transport has no INSERT encoder yet).
//   pool_acquire_overhead        N iterations × withConnection({})
//                                with the body being a no-op. Measures
//                                pure acquire/release cost — no wire
//                                I/O at all.
//   single_select_raw_async      Single-connection async raw baseline
//                                for the same SELECT workload (for
//                                throughput comparison).
//   single_insert_raw_async      Single-connection async raw baseline
//                                for the same INSERT workload.
//
// Output is namespaced [CH PERF RAW-POOL]; the analyzer pairs each
// mode with its single-connection async-raw baseline to expose pool
// scaling.

private func env(_ key: String) -> String? {
    ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 }
}

private func envInt(_ key: String, _ fallback: Int) -> Int {
    guard let raw = env(key), let value = Int(raw) else { return fallback }
    return value
}

private func envString(_ key: String, _ fallback: String) -> String {
    env(key) ?? fallback
}

private let host = envString("CH_BENCH_HOST", "localhost")
private let port = envInt("CH_BENCH_PORT", 9000)
private let user = envString("CH_BENCH_USER", "default")
private let password = envString("CH_BENCH_PASSWORD", "")
private let database = envString("CH_BENCH_DATABASE", "test")

private let ledgerRows = envInt("CH_BENCH_LEDGER_ROWS", 10_000_000)
private let ledgerDatabase = envString("CH_BENCH_LEDGER_DATABASE", "bench_ledgers")
private let ledgerTable = "\(ledgerDatabase).ledger_\(ledgerRows / 1_000_000)M"
private let ledgerUniqueIds = max(1, envInt("CH_BENCH_LEDGER_UNIQUE_IDS", 100_000))

private let poolMinConnections = max(0, envInt("CH_BENCH_POOL_MIN", 1))
private let poolMaxConnections = max(1, envInt("CH_BENCH_POOL_MAX", 8))
private let concurrentTasks = max(1, envInt("CH_BENCH_POOL_TASKS", 100))
private let acquireMicrobenchIterations = max(1, envInt("CH_BENCH_POOL_ACQUIRE_ITERATIONS", 100_000))

private let insertTable = envString("CH_BENCH_POOL_INSERT_TABLE", "test.pool_inserts")

private let modes = envString(
    "CH_BENCH_MODES",
    "pool_acquire_overhead,single_select_raw_async,concurrent_select_raw_pool,single_insert_raw_async,concurrent_insert_raw_pool"
).split(separator: ",").map(String.init)

private func elapsedSeconds(_ start: ContinuousClock.Instant) -> Double {
    let nanos = ContinuousClock.now - start
    return Double(nanos.components.attoseconds) / 1e18 + Double(nanos.components.seconds)
}

private func microsecondsSince(_ start: ContinuousClock.Instant) -> Int64 {
    let nanos = ContinuousClock.now - start
    let seconds = Double(nanos.components.seconds)
    let attos = Double(nanos.components.attoseconds) / 1e18
    return Int64((seconds + attos) * 1_000_000)
}

private func nanosecondsSince(_ start: ContinuousClock.Instant) -> Int64 {
    let nanos = ContinuousClock.now - start
    let seconds = Double(nanos.components.seconds)
    let attos = Double(nanos.components.attoseconds) / 1e18
    return Int64((seconds + attos) * 1_000_000_000)
}

private func percentileMicroseconds(_ sortedSamples: [Int64], _ fraction: Double) -> Int64 {
    guard !sortedSamples.isEmpty else { return 0 }
    let position = max(0, min(sortedSamples.count - 1, Int((Double(sortedSamples.count) * fraction).rounded(.down))))
    return sortedSamples[position]
}

private func reportThroughput(mode: String, tasks: Int, totalSeconds: Double, samples: [Int64], extra: String = "") {
    var sorted = samples
    sorted.sort()
    let p50 = percentileMicroseconds(sorted, 0.50)
    let p95 = percentileMicroseconds(sorted, 0.95)
    let p99 = percentileMicroseconds(sorted, 0.99)
    let maxValue = sorted.last ?? 0
    let total = sorted.reduce(Int64(0), +)
    let mean = sorted.isEmpty ? Int64(0) : total / Int64(sorted.count)
    let perSecond = totalSeconds > 0 ? Int(Double(tasks) / totalSeconds) : 0
    let extraSuffix = extra.isEmpty ? "" : " \(extra)"
    print("[CH PERF RAW-POOL] \(mode) tasks=\(tasks) elapsed=\(String(format: "%.3f", totalSeconds))s throughput=\(perSecond)/s p50_us=\(p50) p95_us=\(p95) p99_us=\(p99) max_us=\(maxValue) mean_us=\(mean)\(extraSuffix)")
}

private func reportAcquireOverhead(iterations: Int, totalSeconds: Double, samplesNanoseconds: [Int64]) {
    var sorted = samplesNanoseconds
    sorted.sort()
    let p50 = percentileMicroseconds(sorted, 0.50)
    let p95 = percentileMicroseconds(sorted, 0.95)
    let p99 = percentileMicroseconds(sorted, 0.99)
    let maxValue = sorted.last ?? 0
    let total = sorted.reduce(Int64(0), +)
    let mean = sorted.isEmpty ? Int64(0) : total / Int64(sorted.count)
    let perSecond = totalSeconds > 0 ? Int(Double(iterations) / totalSeconds) : 0
    print("[CH PERF RAW-POOL] pool_acquire_overhead iterations=\(iterations) elapsed=\(String(format: "%.3f", totalSeconds))s rate=\(perSecond)/s p50_ns=\(p50) p95_ns=\(p95) p99_ns=\(p99) max_ns=\(maxValue) mean_ns=\(mean)")
}

private func ledgerZeroPadded(value: Int, width: Int) -> String {
    var digits: [UInt8] = []
    digits.reserveCapacity(20)
    var remaining = value < 0 ? -value : value
    if remaining == 0 {
        digits.append(0x30)
    } else {
        while remaining > 0 {
            digits.append(UInt8(0x30 &+ (remaining % 10)))
            remaining /= 10
        }
    }
    digits.reverse()
    if digits.count >= width {
        return String(unsafeUninitializedCapacity: width) { buffer in
            for index in 0..<width {
                buffer[index] = digits[index]
            }
            return width
        }
    }
    let padCount = width - digits.count
    return String(unsafeUninitializedCapacity: width) { buffer in
        for index in 0..<padCount {
            buffer[index] = 0x30
        }
        for index in 0..<digits.count {
            buffer[padCount + index] = digits[index]
        }
        return width
    }
}

private func selectSqlForTask(_ taskIndex: Int) -> String {
    let id = ledgerZeroPadded(value: taskIndex % ledgerUniqueIds, width: 44)
    return "SELECT toInt64(count()) FROM \(ledgerTable) WHERE entity_id = '\(id)'"
}

private func insertSqlForTask(_ taskIndex: Int, runTag: Int) -> String {
    // INSERT one row per task. Identifiers carry the run tag so
    // concurrent runs don't collide on the primary key, and so the
    // analyzer can verify all 100 rows landed.
    "INSERT INTO \(insertTable) (run_tag, task_index, payload) VALUES (\(runTag), \(taskIndex), 'concurrent-pool-insert')"
}

private func ensureInsertTable(connection: AsyncClickHouseConnection) async throws {
    try await connection.sendQuery("CREATE DATABASE IF NOT EXISTS test")
    _ = try await connection.drainBlocks()
    try await connection.sendQuery("""
        CREATE TABLE IF NOT EXISTS \(insertTable) (
            run_tag UInt64,
            task_index UInt64,
            payload String,
            inserted_at DateTime DEFAULT now()
        ) ENGINE = MergeTree() ORDER BY (run_tag, task_index)
        """)
    _ = try await connection.drainBlocks()
}

private func runAcquireOverhead(pool: ClickHouseConnectionPool) async throws {
    // Warm-up: prime every connection in the pool so subsequent
    // iterations are all idle-stack hits.
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<poolMaxConnections {
            group.addTask {
                try await pool.withConnection { connection in
                    try await connection.sendQuery("SELECT 1")
                    _ = try await connection.drainBlocks()
                }
            }
        }
        for try await _ in group {}
    }
    var samples = [Int64](repeating: 0, count: acquireMicrobenchIterations)
    let totalStart = ContinuousClock.now
    for index in 0..<acquireMicrobenchIterations {
        let start = ContinuousClock.now
        try await pool.withConnection { _ in
            return ()
        }
        samples[index] = nanosecondsSince(start)
    }
    let totalSeconds = elapsedSeconds(totalStart)
    reportAcquireOverhead(iterations: acquireMicrobenchIterations, totalSeconds: totalSeconds, samplesNanoseconds: samples)
}

private func runConcurrentSelect(pool: ClickHouseConnectionPool, tasks: Int) async throws {
    let samples = SampleSink(capacity: tasks)
    let totalStart = ContinuousClock.now
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<tasks {
            let captured = index
            group.addTask {
                let start = ContinuousClock.now
                _ = try await pool.withConnection { connection in
                    try await connection.sendQuery(selectSqlForTask(captured))
                    return try await connection.receiveScalarUInt64()
                }
                await samples.append(microsecondsSince(start))
            }
        }
        for try await _ in group {}
    }
    let totalSeconds = elapsedSeconds(totalStart)
    let collected = await samples.snapshot()
    reportThroughput(mode: "concurrent_select_raw_pool", tasks: tasks, totalSeconds: totalSeconds, samples: collected, extra: "pool_max=\(poolMaxConnections)")
}

private func runSingleSelectBaseline(connection: AsyncClickHouseConnection, tasks: Int) async throws {
    var samples = [Int64](repeating: 0, count: tasks)
    let totalStart = ContinuousClock.now
    for index in 0..<tasks {
        let start = ContinuousClock.now
        try await connection.sendQuery(selectSqlForTask(index))
        _ = try await connection.receiveScalarUInt64()
        samples[index] = microsecondsSince(start)
    }
    let totalSeconds = elapsedSeconds(totalStart)
    reportThroughput(mode: "single_select_raw_async", tasks: tasks, totalSeconds: totalSeconds, samples: samples, extra: "pool_max=1")
}

private func runConcurrentInsert(pool: ClickHouseConnectionPool, tasks: Int) async throws {
    let runTag = Int(Date().timeIntervalSince1970)
    try await pool.withConnection { connection in
        try await ensureInsertTable(connection: connection)
    }
    let samples = SampleSink(capacity: tasks)
    let totalStart = ContinuousClock.now
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<tasks {
            let captured = index
            group.addTask {
                let start = ContinuousClock.now
                try await pool.withConnection { connection in
                    try await connection.sendQuery(insertSqlForTask(captured, runTag: runTag))
                    _ = try await connection.drainBlocks()
                }
                await samples.append(microsecondsSince(start))
            }
        }
        for try await _ in group {}
    }
    let totalSeconds = elapsedSeconds(totalStart)
    let collected = await samples.snapshot()
    reportThroughput(mode: "concurrent_insert_raw_pool", tasks: tasks, totalSeconds: totalSeconds, samples: collected, extra: "pool_max=\(poolMaxConnections) run_tag=\(runTag)")
}

private func runSingleInsertBaseline(connection: AsyncClickHouseConnection, tasks: Int) async throws {
    let runTag = Int(Date().timeIntervalSince1970) &+ 1
    try await ensureInsertTable(connection: connection)
    var samples = [Int64](repeating: 0, count: tasks)
    let totalStart = ContinuousClock.now
    for index in 0..<tasks {
        let start = ContinuousClock.now
        try await connection.sendQuery(insertSqlForTask(index, runTag: runTag))
        _ = try await connection.drainBlocks()
        samples[index] = microsecondsSince(start)
    }
    let totalSeconds = elapsedSeconds(totalStart)
    reportThroughput(mode: "single_insert_raw_async", tasks: tasks, totalSeconds: totalSeconds, samples: samples, extra: "pool_max=1 run_tag=\(runTag)")
}

private actor SampleSink {
    private var storage: [Int64]
    init(capacity: Int) {
        var initial = [Int64]()
        initial.reserveCapacity(capacity)
        self.storage = initial
    }
    func append(_ value: Int64) { storage.append(value) }
    func snapshot() -> [Int64] { storage }
}

@main
struct PoolBench {

    static func main() async {
        let pool: ClickHouseConnectionPool
        do {
            pool = try await ClickHouseConnectionPool(
                host: host,
                port: port,
                user: user,
                password: password,
                database: database,
                minConnections: poolMinConnections,
                maxConnections: poolMaxConnections
            )
        } catch {
            print("[CH PERF RAW-POOL] FATAL pool init host=\(host) port=\(port) error=\(error)")
            exit(1)
        }
        let singleConnection: AsyncClickHouseConnection
        do {
            singleConnection = try await AsyncClickHouseConnection(
                host: host, port: port, user: user, password: password, database: database
            )
        } catch {
            print("[CH PERF RAW-POOL] FATAL single connect host=\(host) port=\(port) error=\(error)")
            exit(1)
        }

        print("[CH PERF RAW-POOL] config host=\(host) port=\(port) database=\(database) pool_min=\(poolMinConnections) pool_max=\(poolMaxConnections) tasks=\(concurrentTasks) modes=\(modes.joined(separator: ",")) ledger=\(ledgerTable)")

        for selected in modes {
            let trimmed = selected.trimmingCharacters(in: .whitespaces)
            do {
                switch trimmed {
                case "pool_acquire_overhead":
                    try await runAcquireOverhead(pool: pool)
                case "concurrent_select_raw_pool":
                    try await runConcurrentSelect(pool: pool, tasks: concurrentTasks)
                case "concurrent_insert_raw_pool":
                    try await runConcurrentInsert(pool: pool, tasks: concurrentTasks)
                case "single_select_raw_async":
                    try await runSingleSelectBaseline(connection: singleConnection, tasks: concurrentTasks)
                case "single_insert_raw_async":
                    try await runSingleInsertBaseline(connection: singleConnection, tasks: concurrentTasks)
                default:
                    print("[CH PERF RAW-POOL] unknown mode: \(selected)")
                }
            } catch {
                print("[CH PERF RAW-POOL] FAIL mode=\(selected) error=\(error)")
            }
        }

        let finalStats = await pool.stats()
        print("[CH PERF RAW-POOL] final_stats idle=\(finalStats.idleConnections) in_use=\(finalStats.inUseConnections) waiters=\(finalStats.waiters) opened_total=\(finalStats.openedTotal) closed_total=\(finalStats.closedTotal) leases_granted=\(finalStats.leasesGranted) leases_released=\(finalStats.leasesReleased) acquire_timeouts=\(finalStats.acquireTimeouts) max=\(finalStats.maxConnections)")
        let leaked = finalStats.leasesGranted - finalStats.leasesReleased
        if leaked != 0 {
            print("[CH PERF RAW-POOL] FAIL pool leaked \(leaked) leases (granted=\(finalStats.leasesGranted) released=\(finalStats.leasesReleased))")
        } else {
            print("[CH PERF RAW-POOL] OK no leases leaked (granted=\(finalStats.leasesGranted) released=\(finalStats.leasesReleased))")
        }
        if finalStats.inUseConnections != 0 {
            print("[CH PERF RAW-POOL] FAIL pool still has \(finalStats.inUseConnections) in-use connections after all benches")
        }
        if finalStats.waiters != 0 {
            print("[CH PERF RAW-POOL] FAIL pool still has \(finalStats.waiters) waiters after all benches (deadlock candidate)")
        }

        await singleConnection.close()
        await pool.close()
    }
}
