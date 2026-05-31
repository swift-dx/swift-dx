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

func benchPayloadSweep() async throws {
    let rowsPerSize = max(1, payloadSweepEnvInt("SQLITE_BENCH_PAYLOAD_ROWS", 2_000))
    let sizes = payloadSweepSizes("SQLITE_BENCH_PAYLOAD_SIZES", [1_024, 10_240, 102_400, 1_048_576])
    let readerCount = max(1, payloadSweepEnvInt("SQLITE_BENCH_READERS", 8))

    let path = NSTemporaryDirectory() + "dxsqlite-bench-payload-sweep-\(UUID().uuidString).sqlite"
    let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: readerCount))
    let clock = ContinuousClock()

    try await database.write { writer in
        try writer.execute("CREATE TABLE payload (id INTEGER PRIMARY KEY, body BLOB NOT NULL, label TEXT NOT NULL)")
    }

    for size in sizes {
        let blobPayload = payloadSweepBytes(count: size)
        let textPayload = payloadSweepText(count: size)

        try await database.write { writer in
            try writer.execute("DELETE FROM payload")
        }

        let writeStart = clock.now
        try await database.transaction { writer in
            var index = 0
            while index < rowsPerSize {
                _ = try writer.mutate("INSERT INTO payload (id, body, label) VALUES (?, ?, ?)", parameters: [.integer(Int64(index)), .blob(blobPayload), .text(textPayload)])
                index += 1
            }
        }
        payloadSweepReport(size: size, phase: "write_tx", rows: rowsPerSize, bytesPerRow: size, duration: clock.now - writeStart)

        let scanStart = clock.now
        let scannedBytes = try await database.read { reader in
            let rows = try reader.query("SELECT body, label FROM payload")
            var total = 0
            for row in rows {
                total += try row.blob(named: "body").count
                total += try row.text(named: "label").utf8.count
            }
            return total
        }
        let scannedRows = scannedBytes > 0 ? rowsPerSize : 0
        payloadSweepReport(size: size, phase: "read_scan", rows: scannedRows, bytesPerRow: scannedRows > 0 ? scannedBytes / max(1, scannedRows) : 0, duration: clock.now - scanStart)
    }

    await database.close()
    try? FileManager.default.removeItem(atPath: path)
    try? FileManager.default.removeItem(atPath: path + "-wal")
    try? FileManager.default.removeItem(atPath: path + "-shm")
}

private func payloadSweepEnvInt(_ key: String, _ fallback: Int) -> Int {
    Int(ProcessInfo.processInfo.environment[key] ?? "") ?? fallback
}

private func payloadSweepSizes(_ key: String, _ fallback: [Int]) -> [Int] {
    let raw = ProcessInfo.processInfo.environment[key] ?? ""
    let parsed = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 > 0 }
    return parsed.isEmpty ? fallback : parsed
}

private func payloadSweepBytes(count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    var index = 0
    while index < count {
        bytes[index] = UInt8(index & 0xFF)
        index += 1
    }
    return bytes
}

private func payloadSweepText(count: Int) -> String {
    String(repeating: "a", count: count)
}

private func payloadSweepSeconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private func payloadSweepReport(size: Int, phase: String, rows: Int, bytesPerRow: Int, duration: Duration) {
    let elapsed = payloadSweepSeconds(duration)
    let rowsPerSecond = elapsed > 0 ? Double(rows) / elapsed : 0
    let totalBytes = Double(rows) * Double(bytesPerRow)
    let mibPerSecond = elapsed > 0 ? totalBytes / elapsed / 1_048_576.0 : 0
    print("[SQLITE PERF SWIFT] mode=payload_sweep size=\(size) phase=\(phase) rows=\(rows) seconds=\(String(format: "%.3f", elapsed)) rows_per_second=\(Int(rowsPerSecond)) mib_per_second=\(String(format: "%.3f", mibPerSecond))")
}
