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

func benchFunctionOverhead() async throws {
    let rowCount = functionOverheadEnvInt("SQLITE_BENCH_ROWS", 100_000)
    let foldRowCount = functionOverheadEnvInt("SQLITE_BENCH_FOLD_ROWS", rowCount)
    let clock = ContinuousClock()

    let doubleViaSwift = SQLiteFunction(name: "swift_double", argumentCount: 1) { arguments in
        let value = try arguments[0].integer()
        return .integer(value &* 2)
    }
    let sumViaSwift = SQLiteAggregate(name: "swift_sum", argumentCount: 1) {
        FunctionOverheadSum()
    }

    let path = NSTemporaryDirectory() + "dxsqlite-bench-function-overhead-\(UUID().uuidString).sqlite"
    let configuration = SQLiteConfiguration(
        location: .file(path: path),
        functions: [doubleViaSwift],
        aggregates: [sumViaSwift]
    )
    let database = try await SQLite.connect(configuration)

    try await database.write { writer in
        try writer.execute("CREATE TABLE sample (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)")
    }
    try await database.transaction { writer in
        var index = 0
        while index < rowCount {
            _ = try writer.mutate("INSERT INTO sample (id, value) VALUES (?, ?)", parameters: [.integer(Int64(index)), .integer(Int64(index &* 3))])
            index += 1
        }
    }

    let baselineStart = clock.now
    let baselineSum = try await database.read { reader in
        let rows = try reader.query("SELECT value * 2 AS doubled FROM sample")
        var total: Int64 = 0
        for row in rows {
            total &+= try row.integer(named: "doubled")
        }
        return total
    }
    reportFunctionOverhead("baseline", rows: rowCount, checksum: baselineSum, duration: clock.now - baselineStart)

    let customStart = clock.now
    let customSum = try await database.read { reader in
        let rows = try reader.query("SELECT swift_double(value) AS doubled FROM sample")
        var total: Int64 = 0
        for row in rows {
            total &+= try row.integer(named: "doubled")
        }
        return total
    }
    reportFunctionOverhead("custom_scalar", rows: rowCount, checksum: customSum, duration: clock.now - customStart)

    let aggregateRows = min(foldRowCount, rowCount)
    let aggregateStart = clock.now
    let aggregateSum = try await database.read { reader in
        let rows = try reader.query("SELECT swift_sum(value) AS folded FROM sample WHERE id < ?", parameters: [.integer(Int64(aggregateRows))])
        return try rows[0].integer(named: "folded")
    }
    reportFunctionOverhead("aggregate", rows: aggregateRows, checksum: aggregateSum, duration: clock.now - aggregateStart)

    await database.close()
    try? FileManager.default.removeItem(atPath: path)
    try? FileManager.default.removeItem(atPath: path + "-wal")
    try? FileManager.default.removeItem(atPath: path + "-shm")
}

private func functionOverheadEnvInt(_ key: String, _ fallback: Int) -> Int {
    Int(ProcessInfo.processInfo.environment[key] ?? "") ?? fallback
}

private func functionOverheadSeconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private func reportFunctionOverhead(_ variant: String, rows: Int, checksum: Int64, duration: Duration) {
    let elapsed = functionOverheadSeconds(duration)
    let nanosecondsPerRow = rows > 0 ? elapsed * 1e9 / Double(rows) : 0
    print("[SQLITE PERF SWIFT] mode=function_overhead variant=\(variant) rows=\(rows) checksum=\(checksum) seconds=\(String(format: "%.3f", elapsed)) ns_per_row=\(String(format: "%.1f", nanosecondsPerRow))")
}

private final class FunctionOverheadSum: SQLiteAggregator {

    private var total: Int64 = 0

    func step(_ arguments: [SQLiteValue]) throws {
        total &+= try arguments[0].integer()
    }

    func finalize() throws -> SQLiteValue {
        .integer(total)
    }
}
