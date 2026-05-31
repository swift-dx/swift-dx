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

import DXSQLite
import Foundation

// Microbenchmark harness for DXSQLite. SQLite is embedded, so this runs with no
// server against a fresh temp-file database. Each mode prints lines in the
// `[SQLITE PERF SWIFT]` namespace so a parser can pick the numbers up uniformly.
// SQLITE_BENCH_MODE selects which mode to run; "core" (the default) runs the
// four baseline modes, "all" runs every mode, and each mode name runs one.

private func envInt(_ key: String, _ fallback: Int) -> Int {
    Int(ProcessInfo.processInfo.environment[key] ?? "") ?? fallback
}

private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private func report(_ mode: String, operations: Int, duration: Duration) {
    let elapsed = seconds(duration)
    let perSecond = elapsed > 0 ? Double(operations) / elapsed : 0
    print("[SQLITE PERF SWIFT] \(mode) ops=\(operations) seconds=\(String(format: "%.3f", elapsed)) ops_per_second=\(Int(perSecond))")
}

private func runCoreModes() async throws {
    let rowCount = envInt("SQLITE_BENCH_ROWS", 100_000)
    let pointReadCount = envInt("SQLITE_BENCH_READS", 20_000)
    let concurrency = max(1, envInt("SQLITE_BENCH_CONCURRENCY", 8))
    let readerCount = max(concurrency, envInt("SQLITE_BENCH_READERS", 8))

    let path = NSTemporaryDirectory() + "dxsqlite-bench-\(UUID().uuidString).sqlite"
    let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: readerCount))
    let clock = ContinuousClock()

    try await database.write { writer in
        try writer.execute("CREATE TABLE item (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)")
    }

    let writeStart = clock.now
    try await database.transaction { writer in
        var index = 0
        while index < rowCount {
            _ = try writer.mutate("INSERT INTO item (id, value) VALUES (?, ?)", parameters: [.integer(Int64(index)), .integer(Int64(index &* 2))])
            index += 1
        }
    }
    report("write_tx", operations: rowCount, duration: clock.now - writeStart)

    let scanStart = clock.now
    let scanned = try await database.read { reader in
        try reader.query("SELECT id, value FROM item").count
    }
    report("read_scan", operations: scanned, duration: clock.now - scanStart)

    let pointStart = clock.now
    var pointHits = 0
    var lookup = 0
    while lookup < pointReadCount {
        let identifier = Int64(lookup % rowCount)
        let rows = try await database.read { reader in
            try reader.query("SELECT value FROM item WHERE id = ?", parameters: [.integer(identifier)])
        }
        pointHits += rows.count
        lookup += 1
    }
    report("point_read_pooled", operations: pointHits, duration: clock.now - pointStart)

    let perTask = pointReadCount / concurrency
    let concurrentStart = clock.now
    let concurrentHits = try await withThrowingTaskGroup(of: Int.self) { group in
        for worker in 0..<concurrency {
            group.addTask {
                var hits = 0
                var index = 0
                while index < perTask {
                    let identifier = Int64((worker &* perTask &+ index) % rowCount)
                    let rows = try await database.read { reader in
                        try reader.query("SELECT value FROM item WHERE id = ?", parameters: [.integer(identifier)])
                    }
                    hits += rows.count
                    index += 1
                }
                return hits
            }
        }
        var sum = 0
        for try await hits in group {
            sum += hits
        }
        return sum
    }
    report("point_read_concurrent", operations: concurrentHits, duration: clock.now - concurrentStart)

    await database.close()
    try? FileManager.default.removeItem(atPath: path)
    try? FileManager.default.removeItem(atPath: path + "-wal")
    try? FileManager.default.removeItem(atPath: path + "-shm")
}

private func runAllModes() async throws {
    try await runCoreModes()
    try await benchPayloadSweep()
    try await benchBatchSize()
    try await benchPoolSaturation()
    try await benchPreparedReuse()
    try await benchConcurrentWrites()
    try await benchFunctionOverhead()
    try await benchBlobIO()
    try await benchVirtualTableAndFTS()
}

let benchmarkMode = ProcessInfo.processInfo.environment["SQLITE_BENCH_MODE"] ?? "core"

switch benchmarkMode {
case "core": try await runCoreModes()
case "all": try await runAllModes()
case "payload_sweep": try await benchPayloadSweep()
case "batch_size": try await benchBatchSize()
case "pool_saturation": try await benchPoolSaturation()
case "prepared_reuse": try await benchPreparedReuse()
case "concurrent_writes": try await benchConcurrentWrites()
case "function_overhead": try await benchFunctionOverhead()
case "blob_io": try await benchBlobIO()
case "vtable_fts": try await benchVirtualTableAndFTS()
default:
    print("[SQLITE PERF SWIFT] unknown_mode=\(benchmarkMode) valid=core,all,payload_sweep,batch_size,pool_saturation,prepared_reuse,concurrent_writes,function_overhead,blob_io,vtable_fts")
}
