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

func benchBlobIO() async throws {
    let sizes = blobSizes("SQLITE_BENCH_BLOB_SIZES", [4 * 1024, 64 * 1024, 1024 * 1024])
    let iterations = max(1, blobEnvInt("SQLITE_BENCH_BLOB_ITERATIONS", 64))
    let chunkSize = max(1, blobEnvInt("SQLITE_BENCH_BLOB_CHUNK", 64 * 1024))

    let path = NSTemporaryDirectory() + "dxsqlite-bench-blob-\(UUID().uuidString).sqlite"
    let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
    let clock = ContinuousClock()

    try await database.write { writer in
        try writer.execute("CREATE TABLE cell (id INTEGER PRIMARY KEY, payload BLOB NOT NULL)")
    }

    for size in sizes {
        let pattern = blobPattern(count: chunkSize)

        try await database.transaction { writer in
            var index = 0
            while index < iterations {
                _ = try writer.mutate(
                    "INSERT INTO cell (id, payload) VALUES (?, zeroblob(?))",
                    parameters: [.integer(Int64(index + 1)), .integer(Int64(size))]
                )
                index += 1
            }
        }

        let writeStart = clock.now
        try await database.write { writer in
            var index = 0
            while index < iterations {
                let rowID = Int64(index + 1)
                try writer.withBlob(table: "cell", column: "payload", rowID: rowID) { blob in
                    var offset = 0
                    while offset < size {
                        let span = min(chunkSize, size - offset)
                        if span == chunkSize {
                            try blob.write(pattern, at: offset)
                        } else {
                            try blob.write(Array(pattern[0..<span]), at: offset)
                        }
                        offset += span
                    }
                }
                index += 1
            }
        }
        let writeDuration = clock.now - writeStart
        blobReport(operation: "write", size: size, totalBytes: size * iterations, duration: writeDuration)

        let readStart = clock.now
        let readBytes = try await database.read { reader in
            var consumed = 0
            var index = 0
            while index < iterations {
                let rowID = Int64(index + 1)
                consumed += try reader.withBlob(table: "cell", column: "payload", rowID: rowID) { blob in
                    var offset = 0
                    var bytesRead = 0
                    while offset < size {
                        let span = min(chunkSize, size - offset)
                        let slice = try blob.read(count: span, at: offset)
                        bytesRead += slice.count
                        offset += span
                    }
                    return bytesRead
                }
                index += 1
            }
            return consumed
        }
        let readDuration = clock.now - readStart
        blobReport(operation: "read", size: size, totalBytes: readBytes, duration: readDuration)

        try await database.write { writer in
            try writer.execute("DELETE FROM cell")
        }
    }

    await database.close()
    try? FileManager.default.removeItem(atPath: path)
    try? FileManager.default.removeItem(atPath: path + "-wal")
    try? FileManager.default.removeItem(atPath: path + "-shm")
}

private func blobEnvInt(_ key: String, _ fallback: Int) -> Int {
    Int(ProcessInfo.processInfo.environment[key] ?? "") ?? fallback
}

private func blobSizes(_ key: String, _ fallback: [Int]) -> [Int] {
    guard let raw = ProcessInfo.processInfo.environment[key] else {
        return fallback
    }
    let parsed = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 > 0 }
    return parsed.isEmpty ? fallback : parsed
}

private func blobSeconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private func blobPattern(count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    var index = 0
    while index < count {
        bytes[index] = UInt8(index & 0xFF)
        index += 1
    }
    return bytes
}

private func blobReport(operation: String, size: Int, totalBytes: Int, duration: Duration) {
    let elapsed = blobSeconds(duration)
    let mebibytes = Double(totalBytes) / (1024.0 * 1024.0)
    let throughput = elapsed > 0 ? mebibytes / elapsed : 0
    print("[SQLITE PERF SWIFT] mode=blob_io op=\(operation) size=\(size) bytes=\(totalBytes) seconds=\(String(format: "%.3f", elapsed)) mib_per_sec=\(String(format: "%.2f", throughput))")
}
