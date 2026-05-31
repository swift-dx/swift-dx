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

func benchConcurrentWrites() async throws {
    let writeCount = max(1, benchConcurrentWritesEnvInt("SQLITE_BENCH_WRITES", 20_000))
    let taskCount = max(1, benchConcurrentWritesEnvInt("SQLITE_BENCH_WRITE_TASKS", 16))
    let readerCount = max(1, benchConcurrentWritesEnvInt("SQLITE_BENCH_READERS", 8))

    let path = NSTemporaryDirectory() + "dxsqlite-bench-concurrent-writes-\(UUID().uuidString).sqlite"
    let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: readerCount))
    let clock = ContinuousClock()

    try await database.write { writer in
        try writer.execute("CREATE TABLE counter (id INTEGER PRIMARY KEY, total INTEGER NOT NULL)")
        _ = try writer.mutate("INSERT INTO counter (id, total) VALUES (1, 0)")
    }

    let writesPerTask = writeCount / taskCount
    let scheduledWrites = writesPerTask * taskCount

    let writeStart = clock.now
    let appliedWrites = try await withThrowingTaskGroup(of: Int.self) { group in
        for _ in 0..<taskCount {
            group.addTask {
                var applied = 0
                var index = 0
                while index < writesPerTask {
                    let changed = try await database.write { writer in
                        try writer.mutate("UPDATE counter SET total = total + 1 WHERE id = 1")
                    }
                    applied += changed
                    index += 1
                }
                return applied
            }
        }
        var sum = 0
        for try await applied in group {
            sum += applied
        }
        return sum
    }
    let elapsed = benchConcurrentWritesSeconds(clock.now - writeStart)

    let finalTotal = try await database.read { reader in
        let rows = try reader.query("SELECT total FROM counter WHERE id = 1")
        var total: Int64 = -1
        for row in rows {
            total = try row.integer(named: "total")
        }
        return total
    }

    let correct = appliedWrites == scheduledWrites && finalTotal == Int64(scheduledWrites)
    let writesPerSecond = elapsed > 0 ? Double(scheduledWrites) / elapsed : 0
    let meanLatencyMilliseconds = scheduledWrites > 0 ? (elapsed / Double(scheduledWrites)) * 1000.0 : 0

    print("[SQLITE PERF SWIFT] mode=concurrent_writes tasks=\(taskCount) writes=\(scheduledWrites) writes_per_sec=\(Int(writesPerSecond)) mean_latency_ms=\(String(format: "%.4f", meanLatencyMilliseconds)) correct=\(correct)")

    await database.close()
    try? FileManager.default.removeItem(atPath: path)
    try? FileManager.default.removeItem(atPath: path + "-wal")
    try? FileManager.default.removeItem(atPath: path + "-shm")
}

private func benchConcurrentWritesEnvInt(_ key: String, _ fallback: Int) -> Int {
    Int(ProcessInfo.processInfo.environment[key] ?? "") ?? fallback
}

private func benchConcurrentWritesSeconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}
