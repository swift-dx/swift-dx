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

// Minimal benchmark for the optimized DXPostgres package. Exercises only the
// scalar fast path the package exposes: the synchronous direct connection, the
// per-call async pool, and the leasing pool. Mirrors the hot-path perf modes so
// the extracted package can be measured in isolation.

private func env(_ key: String) -> String { ProcessInfo.processInfo.environment[key] ?? "" }
private func envInt(_ key: String, _ fallback: Int) -> Int { Int(env(key)) ?? fallback }
private func envString(_ key: String, _ fallback: String) -> String { let v = env(key); return v.isEmpty ? fallback : v }

private let host = envString("POSTGRES_BENCH_HOST", "127.0.0.1")
private let port = envInt("POSTGRES_BENCH_PORT", 5432)
private let username = envString("POSTGRES_BENCH_USER", "dxpostgres")
private let password = envString("POSTGRES_BENCH_PASSWORD", "dxpostgres")
private let database = envString("POSTGRES_BENCH_DB", "dxpostgres")
private let rowCount = envInt("POSTGRES_BENCH_ROWS", 200_000)
private let iterations = envInt("POSTGRES_BENCH_LATENCY_ITERATIONS", 100_000)
private let concurrency = max(1, envInt("POSTGRES_BENCH_CONCURRENCY", 10))
private let clients = max(1, envInt("POSTGRES_BENCH_CLIENTS", concurrency))
private let modes = envString("POSTGRES_BENCH_MODES", "throughput_scalar,contention_pool_scalar,lease_scalar")
    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

private func elapsedSeconds(_ start: ContinuousClock.Instant) -> Double {
    let duration = ContinuousClock.now - start
    return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private func rate(_ count: Int, _ seconds: Double) -> Int { seconds > 0 ? Int(Double(count) / seconds) : 0 }

private func runThroughputExecute() throws {
    let connection = try PostgresDirectConnection.connect(host: host, port: port, username: username, password: password, database: database, applicationName: "dxlean")
    var matched = 0
    let start = ContinuousClock.now
    for _ in 0..<iterations {
        let result = try connection.execute("SELECT 1 AS n")
        if try result.rows[0][0].text() == "1" { matched += 1 }
    }
    let seconds = elapsedSeconds(start)
    precondition(matched == iterations, "throughput_execute mismatch")
    print("[POSTGRES PERF SWIFT] throughput_execute iterations=\(iterations) elapsed=\(String(format: "%.3f", seconds))s aggregate=\(rate(iterations, seconds))/s")
    connection.close()
}

private func runThroughputStream() throws {
    let connection = try PostgresDirectConnection.connect(host: host, port: port, username: username, password: password, database: database, applicationName: "dxlean")
    var sum: Int64 = 0
    let start = ContinuousClock.now
    for _ in 0..<iterations {
        try connection.execute("SELECT 1 AS n") { (row: PostgresRowView) throws(PostgresError) in
            sum &+= try row.int64(0)
        }
    }
    let seconds = elapsedSeconds(start)
    precondition(sum == Int64(iterations), "throughput_stream mismatch")
    print("[POSTGRES PERF SWIFT] throughput_stream iterations=\(iterations) elapsed=\(String(format: "%.3f", seconds))s aggregate=\(rate(iterations, seconds))/s")
    connection.close()
}

private func runStreamDemo() throws {
    let connection = try PostgresDirectConnection.connect(host: host, port: port, username: username, password: password, database: database, applicationName: "dxlean")
    // Streaming, collected into a variable: the closure reads each borrowed row and
    // appends what it wants to keep, so `labels` is the materialized result.
    var labels: [String] = []
    let columns = try connection.execute("SELECT generate_series(1,3) AS n, 'row-' || generate_series(1,3) AS label") { (row: PostgresRowView) throws(PostgresError) in
        labels.append("\(try row.int64(0)):\(try row.text(1))")
    }
    print("[STREAM DEMO] columns=\(columns.map { $0.name }), collected variable=\(labels)")
    connection.close()
}

private func runThroughputScalar() throws {
    let connection = try PostgresDirectConnection.connect(host: host, port: port, username: username, password: password, database: database, applicationName: "dxlean")
    _ = try connection.queryScalarInt64Inline("SELECT $1::int8 AS n", value: 0)
    var checksum: Int64 = 0
    let start = ContinuousClock.now
    for value in 0..<iterations {
        checksum &+= try connection.queryScalarInt64Inline("SELECT $1::int8 AS n", value: Int64(value))
    }
    let seconds = elapsedSeconds(start)
    var expected: Int64 = 0
    for value in 0..<iterations { expected &+= Int64(value) }
    precondition(checksum == expected, "throughput_scalar checksum mismatch")
    print("[POSTGRES PERF SWIFT] throughput_scalar iterations=\(iterations) elapsed=\(String(format: "%.3f", seconds))s aggregate=\(rate(iterations, seconds))/s")
    connection.close()
}

private func runContentionPoolScalar() async throws {
    let pool = try PostgresBlockingPool(host: host, port: port, username: username, password: password, database: database, applicationName: "dxlean", size: concurrency)
    let perClient = rowCount / clients
    let start = ContinuousClock.now
    let total = try await withThrowingTaskGroup(of: Int.self, returning: Int.self) { group in
        for _ in 0..<clients {
            group.addTask {
                var done = 0
                for value in 0..<perClient {
                    let n = try await pool.queryScalarInt64("SELECT $1::int8 AS n", value: Int64(value))
                    if n == Int64(value) { done += 1 }
                }
                return done
            }
        }
        var collected = 0
        for try await done in group { collected += done }
        return collected
    }
    let seconds = elapsedSeconds(start)
    print("[POSTGRES PERF SWIFT] contention_pool_scalar pool=\(concurrency) clients=\(clients) rows=\(total) elapsed=\(String(format: "%.3f", seconds))s aggregate=\(rate(total, seconds))/s")
    pool.shutdown()
}

private func runLeaseScalar() async throws {
    let pool = try PostgresLeasePool(host: host, port: port, username: username, password: password, database: database, applicationName: "dxlean", size: concurrency)
    let perClient = rowCount / clients
    let start = ContinuousClock.now
    let total = try await withThrowingTaskGroup(of: Int.self, returning: Int.self) { group in
        for _ in 0..<clients {
            group.addTask {
                try await pool.withConnection { connection in
                    var done = 0
                    for value in 0..<perClient {
                        let n = try connection.queryScalarInt64("SELECT $1::int8 AS n", value: Int64(value))
                        if n == Int64(value) { done += 1 }
                    }
                    return done
                }
            }
        }
        var collected = 0
        for try await done in group { collected += done }
        return collected
    }
    let seconds = elapsedSeconds(start)
    print("[POSTGRES PERF SWIFT] lease_scalar pool=\(concurrency) clients=\(clients) rows=\(total) elapsed=\(String(format: "%.3f", seconds))s aggregate=\(rate(total, seconds))/s")
    pool.shutdown()
}

private func runSelectDemo() async throws {
    // The client flow: open a client via the facade, send a statement, read back.
    let postgres = try Postgres.connect(host: host, port: port, username: username, password: password, database: database, applicationName: "dxlean", poolSize: 4)
    defer { postgres.shutdown() }

    let result = try await postgres.execute("SELECT 1 AS id, 'hello world' AS label, NULL::text AS missing, 3.14 AS amount")

    print("[SELECT DEMO] columns: \(result.columns.map { "\($0.name)(oid=\($0.dataTypeObjectID))" }.joined(separator: ", "))")
    let labelIndex = try result.columnIndex(named: "label")
    for (rowIndex, row) in result.rows.enumerated() {
        let labelValue = try row[labelIndex].text()
        let missing = row[2].isNull ? "NULL" : try row[2].text()
        print("  row \(rowIndex): label=\"\(labelValue)\"  missing=\(missing)  all=\(try row.map { $0.isNull ? "NULL" : try $0.text() })")
    }
}

private func runNotifyDemo() async throws {
    let listener = try Postgres.listen(host: host, port: port, username: username, password: password, database: database, applicationName: "dxlisten", channels: ["dx_demo"])
    // Fire three notifications from a separate connection (as a trigger's pg_notify would).
    let notifier = try PostgresDirectConnection.connect(host: host, port: port, username: username, password: password, database: database, applicationName: "dxnotify")
    _ = try notifier.execute("NOTIFY dx_demo, '{\"op\":\"INSERT\",\"id\":1}'")
    _ = try notifier.execute("NOTIFY dx_demo, '{\"op\":\"UPDATE\",\"id\":1}'")
    _ = try notifier.execute("NOTIFY dx_demo, '{\"op\":\"DELETE\",\"id\":1}'")
    notifier.close()
    var received = 0
    for try await note in listener.notifications {
        print("[NOTIFY DEMO] channel=\(note.channel) pid=\(note.processID) payload=\(note.payload)")
        received += 1
        if received == 3 { break }
    }
    listener.close()
}

private func runWatchDemo() async throws {
    let admin = try PostgresDirectConnection.connect(host: host, port: port, username: username, password: password, database: database, applicationName: "dxadmin")
    _ = try admin.execute("DROP TABLE IF EXISTS dx_watch_test")
    _ = try admin.execute("CREATE TABLE dx_watch_test (id int, amount int)")
    admin.close()
    // Watch only rows whose amount > 100 — the filter runs server-side in the trigger.
    let listener = try Postgres.watchTable(host: host, port: port, username: username, password: password, database: database, applicationName: "dxwatch", table: "dx_watch_test", channel: "dx_watch", where: "NEW.amount > 100")
    let writer = try PostgresDirectConnection.connect(host: host, port: port, username: username, password: password, database: database, applicationName: "dxwriter")
    _ = try writer.execute("INSERT INTO dx_watch_test VALUES (1, 50)")              // filtered out
    _ = try writer.execute("INSERT INTO dx_watch_test VALUES (2, 200)")             // matches
    _ = try writer.execute("UPDATE dx_watch_test SET amount = 300 WHERE id = 2")    // matches
    _ = try writer.execute("INSERT INTO dx_watch_test VALUES (3, 80)")              // filtered out
    writer.close()
    print("[WATCH DEMO] inserted amounts 50, 200, updated->300, 80 — expecting only >100 to arrive:")
    var received = 0
    for try await note in listener.notifications {
        print("[WATCH DEMO] got change: \(note.payload)")
        received += 1
        if received == 2 { break }
    }
    listener.close()
}

print("[POSTGRES PERF SWIFT] lean config host=\(host) port=\(port) database=\(database) modes=\(modes.joined(separator: ","))")
for mode in modes {
    do {
        switch mode {
        case "throughput_scalar": try runThroughputScalar()
        case "throughput_execute": try runThroughputExecute()
        case "throughput_stream": try runThroughputStream()
        case "stream_demo": try runStreamDemo()
        case "notify_demo": try await runNotifyDemo()
        case "watch_demo": try await runWatchDemo()
        case "contention_pool_scalar": try await runContentionPoolScalar()
        case "lease_scalar": try await runLeaseScalar()
        case "select_demo": try await runSelectDemo()
        default: print("[POSTGRES PERF SWIFT] unknown mode: \(mode)")
        }
    } catch {
        print("[POSTGRES PERF SWIFT] FAIL mode=\(mode) error=\(error)")
    }
}
