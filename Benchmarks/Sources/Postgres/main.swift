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

import DXPostgres
import Foundation
import NIOPosix

// Microbenchmark harness for DXPostgres. Runs named modes against a live
// PostgreSQL instance and prints a single-line summary per mode in the
// `[POSTGRES PERF SWIFT]` namespace, mirroring the other DXSQLite/DXRedis
// benchmark output so a parser can pick them up uniformly. Point-query modes
// repeat one SQL string so the prepared-statement cache and binary result
// decoding are exercised on the hot path.

private func env(_ key: String) -> String {
    ProcessInfo.processInfo.environment[key] ?? ""
}

private func envInt(_ key: String, _ fallback: Int) -> Int {
    Int(env(key)) ?? fallback
}

private func envString(_ key: String, _ fallback: String) -> String {
    let value = env(key)
    return value.isEmpty ? fallback : value
}

private let host = envString("POSTGRES_BENCH_HOST", "127.0.0.1")
private let port = envInt("POSTGRES_BENCH_PORT", 5432)
private let username = envString("POSTGRES_BENCH_USER", "dxpostgres")
private let password = envString("POSTGRES_BENCH_PASSWORD", "dxpostgres")
private let database = envString("POSTGRES_BENCH_DB", "dxpostgres")
private let rowCount = envInt("POSTGRES_BENCH_ROWS", 100_000)
private let latencyIterations = envInt("POSTGRES_BENCH_LATENCY_ITERATIONS", 20_000)
private let concurrency = max(1, envInt("POSTGRES_BENCH_CONCURRENCY", 8))
private let modes = envString(
    "POSTGRES_BENCH_MODES",
    "select_one,select_one_text,insert,insert_transaction,copy,stream,select_concurrent,latency_select"
).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: max(1, min(concurrency, ProcessInfo.processInfo.activeProcessorCount)))

private let client = PostgresClient(configuration: .init(
    endpoint: .init(host: host, port: port),
    credentials: .password(username: username, password: password),
    database: .init(database),
    eventLoopGroup: eventLoopGroup,
    maxConnections: concurrency,
    maxIdleConnections: concurrency
))

private func elapsedSeconds(_ start: ContinuousClock.Instant) -> Double {
    let duration = ContinuousClock.now - start
    return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private func rate(count: Int, seconds: Double) -> Int {
    seconds > 0 ? Int(Double(count) / seconds) : 0
}

private func summary(_ mode: String, rows: Int, seconds: Double, extra: String) {
    print("[POSTGRES PERF SWIFT] \(mode) rows=\(rows) elapsed=\(String(format: "%.3f", seconds))s rate=\(rate(count: rows, seconds: seconds))/s \(extra)")
}

private func microsecondsSince(_ start: ContinuousClock.Instant) -> Int64 {
    let duration = ContinuousClock.now - start
    return duration.components.seconds * 1_000_000 + duration.components.attoseconds / 1_000_000_000_000
}

private func percentile(_ sorted: [Int64], _ fraction: Double) -> Int64 {
    if sorted.isEmpty { return 0 }
    let position = Int((Double(sorted.count - 1) * fraction).rounded())
    return sorted[min(max(position, 0), sorted.count - 1)]
}

private func latencySummary(_ mode: String, samples: [Int64]) {
    let sorted = samples.sorted()
    let mean = sorted.isEmpty ? 0 : sorted.reduce(Int64(0), +) / Int64(sorted.count)
    print("[POSTGRES PERF SWIFT] \(mode) iterations=\(sorted.count) p50=\(percentile(sorted, 0.5))us p95=\(percentile(sorted, 0.95))us p99=\(percentile(sorted, 0.99))us max=\(sorted.last ?? 0)us mean=\(mean)us")
}

private func runSelectOne() async throws {
    let start = ContinuousClock.now
    for value in 0..<rowCount {
        let row = try await client.query("SELECT $1::int8 AS n", binding: [Int64(value)]).rows[0]
        _ = try row.decode(Int64.self, named: "n")
    }
    summary("select_one", rows: rowCount, seconds: elapsedSeconds(start), extra: "path=extended_binary_prepared")
}

private func runSelectOneText() async throws {
    let start = ContinuousClock.now
    for value in 0..<rowCount {
        let row = try await client.query("SELECT \(value)::int8 AS n").rows[0]
        _ = try row.decode(Int64.self, named: "n")
    }
    summary("select_one_text", rows: rowCount, seconds: elapsedSeconds(start), extra: "path=simple_text")
}

private func runInsert() async throws {
    let table = "dxpg_bench_\(port)"
    _ = try await client.query("DROP TABLE IF EXISTS \(table)")
    _ = try await client.query("CREATE TABLE \(table) (id int8 primary key, label text, amount numeric)")
    let start = ContinuousClock.now
    for value in 0..<rowCount {
        _ = try await client.query("INSERT INTO \(table) (id, label, amount) VALUES ($1, $2, $3)", binding: [Int64(value), "row-\(value)", Int64(value)])
    }
    summary("insert", rows: rowCount, seconds: elapsedSeconds(start), extra: "path=extended_prepared_autocommit")
    _ = try await client.query("DROP TABLE IF EXISTS \(table)")
}

private func runInsertTransaction() async throws {
    let table = "dxpg_bench_tx_\(port)"
    _ = try await client.query("DROP TABLE IF EXISTS \(table)")
    _ = try await client.query("CREATE TABLE \(table) (id int8 primary key, label text, amount numeric)")
    let start = ContinuousClock.now
    try await client.withTransaction { transaction in
        for value in 0..<rowCount {
            _ = try await transaction.query("INSERT INTO \(table) (id, label, amount) VALUES ($1, $2, $3)", binding: [Int64(value), "row-\(value)", Int64(value)])
        }
    }
    summary("insert_transaction", rows: rowCount, seconds: elapsedSeconds(start), extra: "path=single_commit")
    _ = try await client.query("DROP TABLE IF EXISTS \(table)")
}

private func runCopy() async throws {
    let table = "dxpg_bench_copy_\(port)"
    _ = try await client.query("DROP TABLE IF EXISTS \(table)")
    _ = try await client.query("CREATE TABLE \(table) (id int8 primary key, label text, amount numeric)")
    let rows: [[any PostgresEncodable]] = (0..<rowCount).map { [Int64($0), "row-\($0)", Int64($0)] }
    let start = ContinuousClock.now
    let loaded = try await client.copyIn(into: table, columns: ["id", "label", "amount"], rows: rows)
    summary("copy", rows: loaded, seconds: elapsedSeconds(start), extra: "path=copy_from_stdin")
    _ = try await client.query("DROP TABLE IF EXISTS \(table)")
}

private func runStream() async throws {
    let start = ContinuousClock.now
    var seen = 0
    for try await row in client.queryStream("SELECT generate_series(1, \(rowCount))::int8 AS n") {
        _ = try row.decode(Int64.self, named: "n")
        seen += 1
    }
    summary("stream", rows: seen, seconds: elapsedSeconds(start), extra: "path=streamed_simple")
}

private func runSelectConcurrent() async throws {
    let perTask = rowCount / concurrency
    let start = ContinuousClock.now
    let total = try await withThrowingTaskGroup(of: Int.self, returning: Int.self) { group in
        for _ in 0..<concurrency {
            group.addTask {
                for value in 0..<perTask {
                    let row = try await client.query("SELECT $1::int8 AS n", binding: [Int64(value)]).rows[0]
                    _ = try row.decode(Int64.self, named: "n")
                }
                return perTask
            }
        }
        var collected = 0
        for try await done in group {
            collected += done
        }
        return collected
    }
    let seconds = elapsedSeconds(start)
    print("[POSTGRES PERF SWIFT] select_concurrent tasks=\(concurrency) rows=\(total) elapsed=\(String(format: "%.3f", seconds))s aggregate=\(rate(count: total, seconds: seconds))/s")
}

private func runLatencySelect() async throws {
    var samples: [Int64] = []
    samples.reserveCapacity(latencyIterations)
    for value in 0..<latencyIterations {
        let start = ContinuousClock.now
        let row = try await client.query("SELECT $1::int8 AS n", binding: [Int64(value)]).rows[0]
        _ = try row.decode(Int64.self, named: "n")
        samples.append(microsecondsSince(start))
    }
    latencySummary("latency_select", samples: samples)
}

private func run(_ mode: String) async throws {
    switch mode {
    case "select_one": try await runSelectOne()
    case "select_one_text": try await runSelectOneText()
    case "insert": try await runInsert()
    case "insert_transaction": try await runInsertTransaction()
    case "copy": try await runCopy()
    case "stream": try await runStream()
    case "select_concurrent": try await runSelectConcurrent()
    case "latency_select": try await runLatencySelect()
    default: print("[POSTGRES PERF SWIFT] unknown mode: \(mode)")
    }
}

print("[POSTGRES PERF SWIFT] config host=\(host) port=\(port) database=\(database) rows=\(rowCount) concurrency=\(concurrency) modes=\(modes.joined(separator: ","))")

try await client.warmUp(connections: concurrency)

for mode in modes {
    do {
        try await run(mode)
    } catch {
        print("[POSTGRES PERF SWIFT] FAIL mode=\(mode) error=\(error)")
    }
}

await client.shutdown()
try await eventLoopGroup.shutdownGracefully()
