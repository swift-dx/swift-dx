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

import DXClickHouse
import Foundation

// Write-only profiling harness: builds one batch of rows, then inserts it via
// the columnar fast path N times into the dx_wprof Null-engine table (server
// parses then discards, so storage cost is out of the measurement). Isolates
// the client encode + send + server protocol-parse round-trip for callgrind /
// strace / timing without read or storage noise. Row/iteration counts from argv.
struct FastRow: ClickHouseColumnarEncodable, Sendable {

    let id: UInt64
    let name: String
    let value: Double

    static let clickHouseColumnNames = ["id", "name", "value"]

    static func encodeColumnar(_ rows: [FastRow], into sink: inout ClickHouseColumnSink) {
        var ids = [UInt64](); ids.reserveCapacity(rows.count)
        var names = [String](); names.reserveCapacity(rows.count)
        var values = [Double](); values.reserveCapacity(rows.count)
        for row in rows {
            ids.append(row.id)
            names.append(row.name)
            values.append(row.value)
        }
        sink.uint64("id", ids)
        sink.string("name", names)
        sink.double("value", values)
    }
}

let iterations = CommandLine.arguments.count > 1 ? (Int(CommandLine.arguments[1]) ?? 10) : 10
let rowsPerBatch = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 1_000_000) : 1_000_000
let host = ProcessInfo.processInfo.environment["CH_HOST"] ?? "127.0.0.1"
let port = Int(ProcessInfo.processInfo.environment["CH_PORT"] ?? "9000") ?? 9000
let password = ProcessInfo.processInfo.environment["CH_PASSWORD"] ?? "dxtest"

let client = try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")

var batch = [FastRow]()
batch.reserveCapacity(rowsPerBatch)
for n in 0..<rowsPerBatch {
    batch.append(FastRow(id: UInt64(n), name: "row_\(n % 1000)", value: Double(n) * 1.5))
}

func seconds(_ start: ContinuousClock.Instant) -> Double {
    let elapsed = ContinuousClock.now - start
    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
}

var encodeBest = Double.greatestFiniteMagnitude
var encodeChecksum = 0
for _ in 0..<iterations {
    let start = ContinuousClock.now
    var ids = [UInt64](); ids.reserveCapacity(rowsPerBatch)
    var names = [String](); names.reserveCapacity(rowsPerBatch)
    var values = [Double](); values.reserveCapacity(rowsPerBatch)
    for row in batch {
        ids.append(row.id)
        names.append(row.name)
        values.append(row.value)
    }
    encodeBest = min(encodeBest, seconds(start))
    encodeChecksum &+= ids.count &+ names.count &+ values.count
}
FileHandle.standardError.write(Data("[ENCODE-ONLY] \(String(format: "%.4f", encodeBest))s = \(String(format: "%.2f", Double(rowsPerBatch) / encodeBest / 1e6)) M rows/s (rows->columns, cs \(encodeChecksum))\n".utf8))

var best = Double.greatestFiniteMagnitude
for iteration in 0..<iterations {
    let start = ContinuousClock.now
    _ = try await client.insertFast(into: "dx_wprof", rows: batch)
    let elapsed = seconds(start)
    best = min(best, elapsed)
    if iterations <= 3 || iteration == iterations - 1 {
        FileHandle.standardError.write(Data("[WRITE] iter \(iteration): \(rowsPerBatch) rows in \(String(format: "%.4f", elapsed))s = \(String(format: "%.2f", Double(rowsPerBatch) / elapsed / 1e6)) M rows/s\n".utf8))
    }
}
print(String(format: "[WRITE-BEST] %.4fs = %.2f M rows/s", best, Double(rowsPerBatch) / best / 1e6))
await client.close()
