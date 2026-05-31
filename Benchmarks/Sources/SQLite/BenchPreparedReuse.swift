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

func benchPreparedReuse() async throws {
    let rowCount = preparedReuseEnvInt("SQLITE_BENCH_ROWS", 100_000)
    let queryCount = preparedReuseEnvInt("SQLITE_BENCH_PREPARED_QUERIES", 100_000)
    let readerCount = max(1, preparedReuseEnvInt("SQLITE_BENCH_READERS", 8))

    let path = NSTemporaryDirectory() + "dxsqlite-bench-prepared-reuse-\(UUID().uuidString).sqlite"
    let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: readerCount))
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

    let inSessionStart = clock.now
    let inSessionHits = try await database.read { reader in
        var hits = 0
        var index = 0
        while index < queryCount {
            let identifier = Int64(index % rowCount)
            hits += try reader.query("SELECT value FROM item WHERE id = ?", parameters: [.integer(identifier)]).count
            index += 1
        }
        return hits
    }
    preparedReuseReport("in_session", operations: inSessionHits, duration: clock.now - inSessionStart)

    let perCallStart = clock.now
    var perCallHits = 0
    var lookup = 0
    while lookup < queryCount {
        let identifier = Int64(lookup % rowCount)
        let rows = try await database.read { reader in
            try reader.query("SELECT value FROM item WHERE id = ?", parameters: [.integer(identifier)])
        }
        perCallHits += rows.count
        lookup += 1
    }
    preparedReuseReport("per_call", operations: perCallHits, duration: clock.now - perCallStart)

    await database.close()
    try? FileManager.default.removeItem(atPath: path)
    try? FileManager.default.removeItem(atPath: path + "-wal")
    try? FileManager.default.removeItem(atPath: path + "-shm")
}

private func preparedReuseEnvInt(_ key: String, _ fallback: Int) -> Int {
    Int(ProcessInfo.processInfo.environment[key] ?? "") ?? fallback
}

private func preparedReuseSeconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private func preparedReuseReport(_ variant: String, operations: Int, duration: Duration) {
    let elapsed = preparedReuseSeconds(duration)
    let perSecond = elapsed > 0 ? Double(operations) / elapsed : 0
    print("[SQLITE PERF SWIFT] mode=prepared_reuse variant=\(variant) ops=\(operations) seconds=\(String(format: "%.3f", elapsed)) ops_per_sec=\(Int(perSecond))")
}
