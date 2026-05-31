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

func benchPoolSaturation() async throws {
    let rowCount = saturationEnvInt("SQLITE_BENCH_ROWS", 100_000)
    let readsPerLevel = saturationEnvInt("SQLITE_BENCH_SATURATION_READS", 40_000)
    let maxReaders = max(1, saturationEnvInt("SQLITE_BENCH_READERS", 8))

    let path = NSTemporaryDirectory() + "dxsqlite-bench-pool-saturation-\(UUID().uuidString).sqlite"
    let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: maxReaders))
    let clock = ContinuousClock()

    try await database.write { writer in
        try writer.execute("CREATE TABLE item (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)")
    }

    try await database.transaction { writer in
        var index = 0
        while index < rowCount {
            _ = try writer.mutate("INSERT INTO item (id, value) VALUES (?, ?)", parameters: [.integer(Int64(index)), .integer(Int64(index &* 2))])
            index += 1
        }
    }

    let concurrencyLevels = saturationLevels(maxReaders)
    for concurrency in concurrencyLevels {
        let readsPerWorker = max(1, readsPerLevel / concurrency)
        let totalReads = readsPerWorker &* concurrency
        let start = clock.now
        let completed = try await withThrowingTaskGroup(of: Int.self) { group in
            for worker in 0..<concurrency {
                group.addTask {
                    var localReads = 0
                    var index = 0
                    while index < readsPerWorker {
                        let identifier = Int64((worker &* readsPerWorker &+ index) % rowCount)
                        _ = try await database.read { reader in
                            try reader.query("SELECT value FROM item WHERE id = ?", parameters: [.integer(identifier)])
                        }
                        localReads += 1
                        index += 1
                    }
                    return localReads
                }
            }
            var sum = 0
            for try await localReads in group {
                sum += localReads
            }
            return sum
        }
        let elapsed = saturationSeconds(clock.now - start)
        let throughput = elapsed > 0 ? Double(completed) / elapsed : 0
        let meanLatencyMilliseconds = completed > 0 ? (elapsed / Double(completed)) * 1000 : 0
        print("[SQLITE PERF SWIFT] mode=pool_saturation max_readers=\(maxReaders) concurrency=\(concurrency) reads=\(totalReads) throughput=\(Int(throughput)) mean_latency_ms=\(String(format: "%.4f", meanLatencyMilliseconds))")
    }

    await database.close()
    try? FileManager.default.removeItem(atPath: path)
    try? FileManager.default.removeItem(atPath: path + "-wal")
    try? FileManager.default.removeItem(atPath: path + "-shm")
}

private func saturationEnvInt(_ key: String, _ fallback: Int) -> Int {
    Int(ProcessInfo.processInfo.environment[key] ?? "") ?? fallback
}

private func saturationSeconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private func saturationLevels(_ maxReaders: Int) -> [Int] {
    var levels: [Int] = [1]
    for multiplier in [1, 2, 4, 8] {
        let level = maxReaders &* multiplier
        if levels.last != level {
            levels.append(level)
        }
    }
    return levels
}
