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

func benchVirtualTableAndFTS() async throws {
    let smallRows = vtableEnvInt("SQLITE_BENCH_VTABLE_SMALL_ROWS", 100)
    let largeRows = vtableEnvInt("SQLITE_BENCH_VTABLE_LARGE_ROWS", 10_000)
    let scanRepeats = max(1, vtableEnvInt("SQLITE_BENCH_VTABLE_SCAN_REPEATS", 50))
    let documentCount = max(1, vtableEnvInt("SQLITE_BENCH_FTS_DOCS", 10_000))
    let searchQueries = max(1, vtableEnvInt("SQLITE_BENCH_FTS_QUERIES", 2_000))

    let path = NSTemporaryDirectory() + "dxsqlite-bench-vtable-fts-\(UUID().uuidString).sqlite"
    let clock = ContinuousClock()

    for rowTarget in [smallRows, largeRows] {
        let provider = SQLiteStaticTable(name: "entries", columns: ["id", "label", "weight"], rows: vtableRows(count: rowTarget))
        let configuration = SQLiteConfiguration(location: .file(path: path), maxReaders: 1, virtualTables: [provider])
        let database = try await SQLite.connect(configuration)
        let scanStart = clock.now
        var scanned = 0
        var repeatIndex = 0
        while repeatIndex < scanRepeats {
            scanned += try await database.read { reader in
                try reader.query("SELECT id, label, weight FROM entries").count
            }
            repeatIndex += 1
        }
        let elapsed = vtableSeconds(clock.now - scanStart)
        let rowsPerSecond = elapsed > 0 ? Double(scanned) / elapsed : 0
        print("[SQLITE PERF SWIFT] mode=vtable_fts part=vtable_scan rows=\(rowTarget) repeats=\(scanRepeats) rows_per_sec=\(Int(rowsPerSecond))")
        await database.close()
    }

    try? FileManager.default.removeItem(atPath: path)
    try? FileManager.default.removeItem(atPath: path + "-wal")
    try? FileManager.default.removeItem(atPath: path + "-shm")

    let ftsConfiguration = SQLiteConfiguration(location: .file(path: path), maxReaders: 4)
    let ftsDatabase = try await SQLite.connect(ftsConfiguration)

    try await ftsDatabase.write { writer in
        try writer.execute("CREATE VIRTUAL TABLE document USING fts5(body)")
    }

    let indexStart = clock.now
    try await ftsDatabase.transaction { writer in
        var index = 0
        while index < documentCount {
            _ = try writer.mutate("INSERT INTO document (body) VALUES (?)", parameters: [.text(ftsDocument(index))])
            index += 1
        }
    }
    let indexElapsed = vtableSeconds(clock.now - indexStart)
    let documentsPerSecond = indexElapsed > 0 ? Double(documentCount) / indexElapsed : 0
    print("[SQLITE PERF SWIFT] mode=vtable_fts part=fts_index docs=\(documentCount) docs_per_sec=\(Int(documentsPerSecond))")

    let searchStart = clock.now
    var matched = 0
    var queryIndex = 0
    while queryIndex < searchQueries {
        let term = ftsTerm(queryIndex)
        matched += try await ftsDatabase.read { reader in
            try reader.query("SELECT rowid FROM document WHERE document MATCH ?", parameters: [.text(term)]).count
        }
        queryIndex += 1
    }
    let searchElapsed = vtableSeconds(clock.now - searchStart)
    let meanQueryMilliseconds = searchElapsed / Double(searchQueries) * 1_000
    print("[SQLITE PERF SWIFT] mode=vtable_fts part=fts_search docs=\(documentCount) queries=\(searchQueries) matched=\(matched) mean_query_ms=\(String(format: "%.4f", meanQueryMilliseconds))")

    await ftsDatabase.close()
    try? FileManager.default.removeItem(atPath: path)
    try? FileManager.default.removeItem(atPath: path + "-wal")
    try? FileManager.default.removeItem(atPath: path + "-shm")
}

private func vtableEnvInt(_ key: String, _ fallback: Int) -> Int {
    Int(ProcessInfo.processInfo.environment[key] ?? "") ?? fallback
}

private func vtableSeconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private func vtableRows(count: Int) -> [[SQLiteValue]] {
    var rows: [[SQLiteValue]] = []
    rows.reserveCapacity(count)
    var index = 0
    while index < count {
        rows.append([.integer(Int64(index)), .text("label-\(index % 256)"), .real(Double(index) * 1.5)])
        index += 1
    }
    return rows
}

private let ftsVocabulary = [
    "alpha", "bravo", "charlie", "delta", "echo", "foxtrot",
    "golf", "hotel", "india", "juliet", "kilo", "lima",
    "mike", "november", "oscar", "papa", "quebec", "romeo",
    "sierra", "tango", "uniform", "victor", "whiskey", "xray",
    "yankee", "zulu", "zero", "one", "two", "three", "four", "five"
]

private func ftsDocument(_ index: Int) -> String {
    var words: [String] = []
    words.reserveCapacity(12)
    var offset = 0
    while offset < 12 {
        words.append(ftsVocabulary[(index &+ offset &* 7) % ftsVocabulary.count])
        offset += 1
    }
    return words.joined(separator: " ")
}

private func ftsTerm(_ index: Int) -> String {
    ftsVocabulary[index % ftsVocabulary.count]
}
