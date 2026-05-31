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

func benchBatchSize() async throws {
    let totalRows = batchSizeEnvInt("SQLITE_BENCH_BATCH_TOTAL_ROWS", 200_000)
    let batchSizes = batchSizeParseList("SQLITE_BENCH_BATCH_SIZES", [1, 10, 100, 1000, 10000])

    let path = NSTemporaryDirectory() + "dxsqlite-bench-batch-size-\(UUID().uuidString).sqlite"
    let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 1))
    let clock = ContinuousClock()

    try await database.write { writer in
        try writer.execute("CREATE TABLE item (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)")
    }

    for batch in batchSizes {
        let mutationsPerBatch = max(1, batch)
        let batchCount = max(1, totalRows / mutationsPerBatch)
        let mutations = batchCount * mutationsPerBatch

        try await database.write { writer in
            try writer.execute("DELETE FROM item")
        }

        let start = clock.now
        var batchIndex = 0
        while batchIndex < batchCount {
            let batchBase = batchIndex * mutationsPerBatch
            try await database.transaction { writer in
                var withinBatch = 0
                while withinBatch < mutationsPerBatch {
                    let identifier = batchBase + withinBatch
                    _ = try writer.mutate(
                        "INSERT OR REPLACE INTO item (id, value) VALUES (?, ?)",
                        parameters: [.integer(Int64(identifier)), .integer(Int64(identifier &* 2))]
                    )
                    withinBatch += 1
                }
            }
            batchIndex += 1
        }
        let elapsed = batchSizeSeconds(clock.now - start)
        let rowsPerSecond = elapsed > 0 ? Double(mutations) / elapsed : 0
        let meanLatencyMicroseconds = mutations > 0 ? (elapsed / Double(mutations)) * 1_000_000 : 0

        print("[SQLITE PERF SWIFT] mode=batch_size batch=\(mutationsPerBatch) mutations=\(mutations) seconds=\(String(format: "%.3f", elapsed)) rows_per_second=\(Int(rowsPerSecond)) mean_mutation_microseconds=\(String(format: "%.3f", meanLatencyMicroseconds))")
    }

    await database.close()
    try? FileManager.default.removeItem(atPath: path)
    try? FileManager.default.removeItem(atPath: path + "-wal")
    try? FileManager.default.removeItem(atPath: path + "-shm")
}

private func batchSizeEnvInt(_ key: String, _ fallback: Int) -> Int {
    Int(ProcessInfo.processInfo.environment[key] ?? "") ?? fallback
}

private func batchSizeParseList(_ key: String, _ fallback: [Int]) -> [Int] {
    let raw = ProcessInfo.processInfo.environment[key] ?? ""
    let parsed = raw
        .split(separator: ",")
        .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        .filter { $0 > 0 }
    return parsed.isEmpty ? fallback : parsed
}

private func batchSizeSeconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}
