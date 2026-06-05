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

// Swift DXClickHouse benchmark matched 1:1 with the C++ clickhouse-cpp
// benchmark: same server, same (UInt64, String, Float64) schema, same total
// row count and batch size, native protocol with no wire compression.
struct Row: Codable, Sendable {
    let id: UInt64
    let name: String
    let value: Double
}

// Fused single-pass read (lowest overhead, the C++-parity reference path).
struct FusedRow: ClickHouseFusedDecodable, Sendable {
    let id: UInt64
    let name: String
    let value: Double
    static let clickHouseColumnNames = ["id", "name", "value"]
    static func decodeFused(_ block: ClickHouseRawBlock) throws(ClickHouseError) -> [FusedRow] {
        var rows = [FusedRow](); rows.reserveCapacity(block.count)
        for i in 0..<block.count {
            rows.append(FusedRow(id: block.uint64(0, i), name: block.string(1, i), value: block.double(2, i)))
        }
        return rows
    }
}

// Hand-written stand-in for what @ClickHouseRow will generate (read + write).
struct FastRow: ClickHouseRowDecodable, ClickHouseColumnarEncodable, Sendable {
    let id: UInt64
    let name: String
    let value: Double
    static let clickHouseColumnNames = ["id", "name", "value"]
    init(id: UInt64, name: String, value: Double) { self.id = id; self.name = name; self.value = value }
    static func decodeBlock(_ block: ClickHouseColumnBlock) throws(ClickHouseError) -> [FastRow] {
        let ids = try block.uint64(0)
        let names = try block.strings(1)
        let values = try block.double(2)
        var rows = [FastRow](); rows.reserveCapacity(block.count)
        for i in 0..<block.count { rows.append(FastRow(id: ids[i], name: names[i], value: values[i])) }
        return rows
    }
    static func encodeColumnar(_ rows: [FastRow], into sink: inout ClickHouseColumnSink) {
        var ids = [UInt64](); ids.reserveCapacity(rows.count)
        var names = [String](); names.reserveCapacity(rows.count)
        var values = [Double](); values.reserveCapacity(rows.count)
        for row in rows { ids.append(row.id); names.append(row.name); values.append(row.value) }
        sink.uint64("id", ids)
        sink.string("name", names)
        sink.double("value", values)
    }
}

func seconds(_ start: ContinuousClock.Instant) -> Double {
    let elapsed = ContinuousClock.now - start
    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
}

let total = 1_000_000
let batch = 100_000
let table = "dx_swiftbench"

let client = try await ClickHouseClient(host: "127.0.0.1", port: 9000, user: "default", password: "dxtest", database: "default")
try await client.execute("DROP TABLE IF EXISTS \(table)")
try await client.execute("CREATE TABLE \(table) (id UInt64, name String, value Float64) ENGINE = Memory")

// ---- WRITE ----
let writeStart = ContinuousClock.now
var maxBatchLatency = 0.0
var base = 0
while base < total {
    var rows: [Row] = []
    rows.reserveCapacity(batch)
    for i in 0..<batch {
        let n = base + i
        rows.append(Row(id: UInt64(n), name: "row_\(n % 1000)", value: Double(n) * 1.5))
    }
    let batchStart = ContinuousClock.now
    _ = try await client.insert(into: table, rows: rows)
    maxBatchLatency = max(maxBatchLatency, seconds(batchStart))
    base += batch
}
let writeSec = seconds(writeStart)

// ---- WRITE (columnar fast path) ----
try await client.execute("TRUNCATE TABLE \(table)")
let writeFastStart = ContinuousClock.now
var maxFastBatch = 0.0
var fbase = 0
while fbase < total {
    var batchRows: [FastRow] = []
    batchRows.reserveCapacity(batch)
    for i in 0..<batch {
        let n = fbase + i
        batchRows.append(FastRow(id: UInt64(n), name: "row_\(n % 1000)", value: Double(n) * 1.5))
    }
    let batchStart = ContinuousClock.now
    _ = try await client.insertFast(into: table, rows: batchRows)
    maxFastBatch = max(maxFastBatch, seconds(batchStart))
    fbase += batch
}
let writeFastSec = seconds(writeFastStart)

// ---- READ (Codable) ----
let readStart = ContinuousClock.now
let back = try await client.selectAll("SELECT id, name, value FROM \(table)", as: Row.self)
let readSec = seconds(readStart)
var checksum: UInt64 = 0
for row in back { checksum = checksum &+ row.id }

// ---- READ (columnar fast path) ----
let fastStart = ContinuousClock.now
let fast = try await client.selectAllFast("SELECT id, name, value FROM \(table)", as: FastRow.self)
let fastSec = seconds(fastStart)
var fastChecksum: UInt64 = 0
for row in fast { fastChecksum = fastChecksum &+ row.id }

// ---- READ (fused single-pass path) ----
let fusedStart = ContinuousClock.now
let fused = try await client.selectAllFused("SELECT id, name, value FROM \(table)", as: FusedRow.self)
let fusedSec = seconds(fusedStart)
var fusedChecksum: UInt64 = 0
for row in fused { fusedChecksum = fusedChecksum &+ row.id }

try await client.execute("DROP TABLE \(table)")
await client.close()

print(String(format: "[SWIFT] write      %d rows in %.3fs = %.2f M rows/s (max batch latency %.1f ms)",
             total, writeSec, Double(total) / writeSec / 1e6, maxBatchLatency * 1000.0))
print(String(format: "[SWIFT] write-fast %d rows in %.3fs = %.2f M rows/s (max batch latency %.1f ms)",
             total, writeFastSec, Double(total) / writeFastSec / 1e6, maxFastBatch * 1000.0))
print(String(format: "[SWIFT] read      %d rows in %.3fs = %.2f M rows/s (checksum %llu)",
             back.count, readSec, Double(back.count) / readSec / 1e6, checksum))
print(String(format: "[SWIFT] read-fast %d rows in %.3fs = %.2f M rows/s (checksum %llu)",
             fast.count, fastSec, Double(fast.count) / fastSec / 1e6, fastChecksum))
print(String(format: "[SWIFT] read-fused %d rows in %.3fs = %.2f M rows/s (checksum %llu)",
             fused.count, fusedSec, Double(fused.count) / fusedSec / 1e6, fusedChecksum))
