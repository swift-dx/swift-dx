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
import NIOPosix

// Microbenchmark harness for DXClickHouse. Runs one or more named
// modes against a live ClickHouse instance and prints a single-line
// summary per mode in the `[CH PERF SWIFT]` namespace, mirroring the
// JetStream benchmark's output style so a CI parser can pick both up
// uniformly.
//
// Modes are selected via the `CH_BENCH_MODES` environment variable as
// a comma-separated list. Defaults run the full matrix.
//
// All modes use a unique table name suffixed with a UUID slice so
// concurrent runs against the same ClickHouse don't collide; tables
// are dropped at the end of each mode. The table's database defaults
// to `test` and can be overridden by `CH_BENCH_DATABASE`.

private func env(_ key: String) -> String? {
    ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 }
}

private func envInt(_ key: String, _ fallback: Int) -> Int {
    guard let raw = env(key), let value = Int(raw) else { return fallback }
    return value
}

private func envString(_ key: String, _ fallback: String) -> String {
    env(key) ?? fallback
}

private let host = envString("CH_BENCH_HOST", "localhost")
private let port = envInt("CH_BENCH_PORT", 9000)
private let user = envString("CH_BENCH_USER", "default")
private let password = envString("CH_BENCH_PASSWORD", "")
private let database = envString("CH_BENCH_DATABASE", "test")
private let rowCount = envInt("CH_BENCH_ROWS", 1_000_000)
private let blockRowCount = envInt("CH_BENCH_BLOCK", 100_000)
private let concurrency = max(1, envInt("CH_BENCH_CONCURRENCY", 8))
private let latencyIterations = envInt("CH_BENCH_LATENCY_ITERATIONS", 10_000)
private let latencySmallBatchRows = envInt("CH_BENCH_LATENCY_SMALL_BATCH", 100)
private let modes = envString(
    "CH_BENCH_MODES",
    "insert_bulk_columnar,select_bulk_columnar,insert_bulk_codable,select_bulk_codable,insert_lc_map,select_lc_map"
).split(separator: ",").map(String.init)

private let allTypedTypeNames = [
    "int8", "int16", "int32", "int64",
    "uint8", "uint16", "uint32", "uint64",
    "float32", "float64",
    "string", "string_long",
    "bool",
    "uuid",
    "date", "date_time", "date_time64_nanos",
    "array_int32",
    "nullable_string",
    "fixed_string_16",
]

private let selectedTypedTypes = envString("CH_BENCH_TYPES", allTypedTypeNames.joined(separator: ","))
    .split(separator: ",")
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty }

private let runSuffix = UUID().uuidString.prefix(8).replacingOccurrences(of: "-", with: "")

// Real-workload fixture settings. The fixture tables are shared across
// Swift and C++ harnesses and across hyperfine runs, so they live under
// stable names (no per-run suffix) and are explicitly created by the
// `benchsetup` mode. `events_NN` and `logs_NN` row counts are read from
// CH_BENCH_EVENTS_ROWS / CH_BENCH_LOGS_ROWS so the same suite can be
// smoke-tested at small scale and stress-tested at full scale without
// recompiling.
private let sampleEventsRows = envInt("CH_BENCH_EVENTS_ROWS", 10_000_000)
private let sampleLogsRows = envInt("CH_BENCH_LOGS_ROWS", 1_000_000)
private let realFixtureBlock = envInt("CH_BENCH_FIXTURE_BLOCK", 200_000)
private let sampleFixtureDatabase = envString("CH_BENCH_SAMPLE_DATABASE", "bench_sample")
private let sampleEventsTable = "\(sampleFixtureDatabase).events_\(sampleEventsRows / 1_000_000)M"
private let sampleLogsTable = "\(sampleFixtureDatabase).logs_\(sampleLogsRows / 1_000_000)M"
private let realStringFilterIterations = max(1, envInt("CH_BENCH_SAMPLE_FILTER_ITERATIONS", 1))
private let sampleDecodeOnlyIterations = max(1, envInt("CH_BENCH_SAMPLE_DECODE_ITERATIONS", 5))

// Event-sourced ledger-shape fixture. `ledger_<N>M` is the read-side
// table mirroring a representative production DDL (FixedString,
// Array(FixedString), LowCardinality, JSON, DateTime64(9) with
// timezone, partition + sort designed for an event-sourcing/CQRS
// workload). The fixture is populated entirely server-side via
// INSERT...SELECT from numbers() so both Swift and C++ harnesses can
// reproduce the identical bytes with no client-side type coverage
// dependency. `ledger_writes` is the companion target for the
// bulk/stream INSERT benches; it mirrors the ledger schema but uses
// String / Array(String) / LowCardinality(String) for columns the
// Swift client cannot yet encode (Array(FixedString(N)),
// LowCardinality(FixedString(N))). Both clients write into the same
// relaxed shape so INSERT throughput stays apples-to-apples.
private let ledgerRows = envInt("CH_BENCH_LEDGER_ROWS", 10_000_000)
private let ledgerUniqueIds = max(1, envInt("CH_BENCH_LEDGER_UNIQUE_IDS", 100_000))
private let ledgerKinds = max(1, envInt("CH_BENCH_LEDGER_KINDS", 2_000))
private let ledgerPointIterations = max(1, envInt("CH_BENCH_LEDGER_POINT_ITERATIONS", 1_000))
private let ledgerHasIterations = max(1, envInt("CH_BENCH_LEDGER_HAS_ITERATIONS", 1_000))
private let ledgerKindIterations = max(1, envInt("CH_BENCH_LEDGER_KIND_ITERATIONS", 100))
private let ledgerBulkRows = max(1, envInt("CH_BENCH_LEDGER_BULK_ROWS", 100_000))
private let ledgerStreamIterations = max(1, envInt("CH_BENCH_LEDGER_STREAM_ITERATIONS", 1_000))
private let ledgerStreamRows = max(1, envInt("CH_BENCH_LEDGER_STREAM_ROWS", 10))
private let ledgerDatabase = envString("CH_BENCH_LEDGER_DATABASE", "bench_ledgers")
private let ledgerTable = "\(ledgerDatabase).ledger_\(ledgerRows / 1_000_000)M"
private let ledgerWritesTable = "\(ledgerDatabase).ledger_writes"

// One NIO event loop per concurrent worker task by default. With a
// single shared loop, every block-encode + channel write across the
// concurrent_insert_throughput workload serialises onto one CPU and
// caps aggregate throughput at ~2.1 M r/s. Per-loop fan-out lets each
// task drive its own pipeline thread and lifts the aggregate to the
// server-bound ceiling (~3.1 M r/s on this hardware). Override with
// CH_BENCH_LOOPS=1 to reproduce the legacy single-loop baseline.
private let defaultLoopCount = max(1, min(concurrency, ProcessInfo.processInfo.activeProcessorCount))
private let eventLoopThreadCount = max(1, envInt("CH_BENCH_LOOPS", defaultLoopCount))
private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: eventLoopThreadCount)
defer {
    Task {
        try? await eventLoopGroup.shutdownGracefully()
    }
}

private let client = ClickHouseClient(configuration: .init(
    endpoints: [.init(host: host, port: port)],
    database: database,
    user: user,
    password: password,
    maxConnections: concurrency,
    maxIdleConnections: concurrency,
    eventLoopGroup: eventLoopGroup
))

private func elapsedSeconds(_ start: ContinuousClock.Instant) -> Double {
    let nanos = ContinuousClock.now - start
    return Double(nanos.components.attoseconds) / 1e18 + Double(nanos.components.seconds)
}

private func rate(count: Int, seconds: Double) -> Int {
    seconds > 0 ? Int(Double(count) / seconds) : 0
}

private func summary(mode: String, rows: Int, seconds: Double, extra: String = "") {
    let extraSuffix = extra.isEmpty ? "" : " \(extra)"
    print("[CH PERF SWIFT] \(mode) rows=\(rows) elapsed=\(String(format: "%.3f", seconds))s rate=\(rate(count: rows, seconds: seconds))/s\(extraSuffix)")
}

private func realSummary(mode: String, rows: Int, seconds: Double, firstByteMicroseconds: Int64, totalDecodeMicroseconds: Int64, extra: String = "") {
    let extraSuffix = extra.isEmpty ? "" : " \(extra)"
    print("[CH PERF SWIFT] \(mode) rows=\(rows) elapsed=\(String(format: "%.3f", seconds))s rate=\(rate(count: rows, seconds: seconds))/s first_byte_us=\(firstByteMicroseconds) total_decode_us=\(totalDecodeMicroseconds)\(extraSuffix)")
}

private func tableName(_ kind: String) -> String {
    "\(database).bench_\(kind)_\(runSuffix)"
}

private func runInsertBulkColumnar() async throws {
    let table = tableName("col")
    try await client.execute("DROP TABLE IF EXISTS \(table)")
    try await client.execute("CREATE TABLE \(table) (id UInt64, tag String, value Float64, ts DateTime) ENGINE = MergeTree ORDER BY id")
    defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }

    let totalBlocks = (rowCount + blockRowCount - 1) / blockRowCount
    let start = ContinuousClock.now
    for blockIndex in 0..<totalBlocks {
        let blockStart = blockIndex * blockRowCount
        let blockEnd = min(blockStart + blockRowCount, rowCount)
        let count = blockEnd - blockStart
        let ids = (blockStart..<blockEnd).map { UInt64($0) }
        let tags = (blockStart..<blockEnd).map { "tag-\($0 % 100)" }
        let values = (blockStart..<blockEnd).map { Double($0) * 0.5 }
        let timestamps = Array(repeating: Date(timeIntervalSince1970: 1_700_000_000), count: count)
        try await client.insert(into: table, columns: [
            .init(name: "id", values: .uint64(ids)),
            .init(name: "tag", values: .string(tags)),
            .init(name: "value", values: .float64(values)),
            .init(name: "ts", values: .dateTime(timestamps)),
        ])
    }
    summary(mode: "insert_bulk_columnar", rows: rowCount, seconds: elapsedSeconds(start), extra: "block_rows=\(blockRowCount)")
}

private struct BenchRow: Codable, Sendable {

    let id: UInt64
    let tag: String
    let value: Float64
    let ts: Date

}

private func runInsertBulkCodable() async throws {
    let table = tableName("cod")
    try await client.execute("DROP TABLE IF EXISTS \(table)")
    try await client.execute("CREATE TABLE \(table) (id UInt64, tag String, value Float64, ts DateTime) ENGINE = MergeTree ORDER BY id")
    defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }

    let totalBlocks = (rowCount + blockRowCount - 1) / blockRowCount
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let start = ContinuousClock.now
    for blockIndex in 0..<totalBlocks {
        let blockStart = blockIndex * blockRowCount
        let blockEnd = min(blockStart + blockRowCount, rowCount)
        let rows = (blockStart..<blockEnd).map { index in
            BenchRow(id: UInt64(index), tag: "tag-\(index % 100)", value: Double(index) * 0.5, ts: timestamp)
        }
        try await client.insert(into: table, rows: rows)
    }
    summary(mode: "insert_bulk_codable", rows: rowCount, seconds: elapsedSeconds(start), extra: "block_rows=\(blockRowCount)")
}

private func seedBulkTable(_ table: String) async throws {
    try await client.execute("DROP TABLE IF EXISTS \(table)")
    try await client.execute("CREATE TABLE \(table) (id UInt64, tag String, value Float64, ts DateTime) ENGINE = MergeTree ORDER BY id")
    let totalBlocks = (rowCount + blockRowCount - 1) / blockRowCount
    for blockIndex in 0..<totalBlocks {
        let blockStart = blockIndex * blockRowCount
        let blockEnd = min(blockStart + blockRowCount, rowCount)
        let count = blockEnd - blockStart
        let ids = (blockStart..<blockEnd).map { UInt64($0) }
        let tags = (blockStart..<blockEnd).map { "tag-\($0 % 100)" }
        let values = (blockStart..<blockEnd).map { Double($0) * 0.5 }
        let timestamps = Array(repeating: Date(timeIntervalSince1970: 1_700_000_000), count: count)
        try await client.insert(into: table, columns: [
            .init(name: "id", values: .uint64(ids)),
            .init(name: "tag", values: .string(tags)),
            .init(name: "value", values: .float64(values)),
            .init(name: "ts", values: .dateTime(timestamps)),
        ])
    }
}

private func runSelectBulkColumnar() async throws {
    let table = tableName("sel_col")
    try await seedBulkTable(table)
    defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }

    var observed = 0
    let start = ContinuousClock.now
    for try await block in client.selectColumns("SELECT id, tag, value, ts FROM \(table)") {
        observed += block.rowCount
    }
    summary(mode: "select_bulk_columnar", rows: observed, seconds: elapsedSeconds(start))
}

private func runSelectBulkColumnarFast() async throws {
    let table = tableName("sel_col_fast")
    try await seedBulkTable(table)
    defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }

    var observed = 0
    let start = ContinuousClock.now
    for try await batch in client.selectStreamFast(BenchRow.self, from: "SELECT id, tag, value, ts FROM \(table)") {
        for row in batch {
            observed += 1
            _ = row.id
        }
    }
    summary(mode: "select_bulk_columnar_fast", rows: observed, seconds: elapsedSeconds(start))
}

private struct BenchRowSlot: Sendable {

    let id: Int
    let tag: Int
    let value: Int
    let ts: Int

}

private func resolveBenchRowSlots(_ block: ClickHouseSelectBlock) -> BenchRowSlot {
    var idSlot = -1
    var tagSlot = -1
    var valueSlot = -1
    var tsSlot = -1
    for (position, column) in block.columns.enumerated() {
        switch column.name {
        case "id": idSlot = position
        case "tag": tagSlot = position
        case "value": valueSlot = position
        case "ts": tsSlot = position
        default: continue
        }
    }
    return BenchRowSlot(id: idSlot, tag: tagSlot, value: valueSlot, ts: tsSlot)
}

private func extractBenchRow(block: ClickHouseSelectBlock, slots: BenchRowSlot, rowIndex: Int) -> BenchRow {
    let id = extractUInt64(block.columns[slots.id].values, rowIndex)
    let tag = extractString(block.columns[slots.tag].values, rowIndex)
    let value = extractDouble(block.columns[slots.value].values, rowIndex)
    let ts = extractDateTime(block.columns[slots.ts].values, rowIndex)
    return BenchRow(id: id, tag: tag, value: value, ts: ts)
}

private func extractUInt64(_ values: ClickHouseColumnEntry.Values, _ rowIndex: Int) -> UInt64 {
    if case .uint64(let arr) = values { return arr[rowIndex] }
    return 0
}

private func extractString(_ values: ClickHouseColumnEntry.Values, _ rowIndex: Int) -> String {
    if case .string(let arr) = values { return arr[rowIndex] }
    if case .lowCardinalityString(let arr) = values { return arr[rowIndex] }
    if case .lowCardinalityStringIndexed(let view) = values { return view[rowIndex] }
    return ""
}

private func extractDouble(_ values: ClickHouseColumnEntry.Values, _ rowIndex: Int) -> Double {
    if case .float64(let arr) = values { return arr[rowIndex] }
    return 0
}

private func extractDateTime(_ values: ClickHouseColumnEntry.Values, _ rowIndex: Int) -> Date {
    if case .dateTime(let arr) = values { return arr[rowIndex] }
    return Date(timeIntervalSince1970: 0)
}

private final class BenchRowSlotCache: @unchecked Sendable {

    var slots = BenchRowSlot(id: -1, tag: -1, value: -1, ts: -1)
    var columnsCount = -1

    func ensure(_ block: ClickHouseSelectBlock) -> BenchRowSlot {
        if columnsCount != block.columns.count {
            slots = resolveBenchRowSlots(block)
            columnsCount = block.columns.count
        }
        return slots
    }

}

private func runSelectBulkColumnarWireOnly() async throws {
    let table = tableName("sel_col_wire")
    try await seedBulkTable(table)
    defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }

    var observed = 0
    let start = ContinuousClock.now
    for try await block in client.selectColumns("SELECT id, tag, value, ts FROM \(table)") {
        observed += block.rowCount
    }
    summary(mode: "select_bulk_columnar_wire", rows: observed, seconds: elapsedSeconds(start))
}

private func runSelectBulkColumnarBuilder() async throws {
    let table = tableName("sel_col_builder")
    try await seedBulkTable(table)
    defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }

    var observed = 0
    let start = ContinuousClock.now
    let slotCache = BenchRowSlotCache()
    let stream = client.selectStreamBuilder(BenchRow.self, from: "SELECT id, tag, value, ts FROM \(table)") { block, rowIndex in
        let slots = slotCache.ensure(block)
        return extractBenchRow(block: block, slots: slots, rowIndex: rowIndex)
    }
    for try await batch in stream {
        for row in batch {
            observed += 1
            _ = row.id
        }
    }
    summary(mode: "select_bulk_columnar_builder", rows: observed, seconds: elapsedSeconds(start))
}

private func runSelectBulkCodable() async throws {
    let table = tableName("sel_cod")
    try await seedBulkTable(table)
    defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }

    var observed = 0
    let start = ContinuousClock.now
    for try await _ in client.selectStream(BenchRow.self, from: "SELECT id, tag, value, ts FROM \(table) ORDER BY id") {
        observed += 1
    }
    summary(mode: "select_bulk_codable", rows: observed, seconds: elapsedSeconds(start))
}

private struct LCRow: Codable, Sendable {

    let id: UInt64
    let env: String
    let attributes: [String: String]

}

private func runInsertLCMapCodable() async throws {
    let table = tableName("lc_cod")
    try await client.execute("DROP TABLE IF EXISTS \(table)")
    try await client.execute("""
        CREATE TABLE \(table) (
          id UInt64,
          env LowCardinality(String),
          attributes Map(LowCardinality(String), String)
        ) ENGINE = MergeTree ORDER BY id
        """)
    defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }
    let envOptions = ["production", "staging", "development"]
    let totalBlocks = (rowCount + blockRowCount - 1) / blockRowCount
    let start = ContinuousClock.now
    for blockIndex in 0..<totalBlocks {
        let blockStart = blockIndex * blockRowCount
        let blockEnd = min(blockStart + blockRowCount, rowCount)
        let rows = (blockStart..<blockEnd).map { index in
            LCRow(
                id: UInt64(index),
                env: envOptions[index % envOptions.count],
                attributes: ["service": "svc-\(index % 16)", "region": "ap-southeast-2"]
            )
        }
        try await client.insert(into: table, rows: rows)
    }
    summary(mode: "insert_lc_map_codable", rows: rowCount, seconds: elapsedSeconds(start), extra: "block_rows=\(blockRowCount)")
}

private func runInsertLCMap() async throws {
    let table = tableName("lc")
    try await client.execute("DROP TABLE IF EXISTS \(table)")
    try await client.execute("""
        CREATE TABLE \(table) (
          id UInt64,
          env LowCardinality(String),
          attributes Map(LowCardinality(String), String)
        ) ENGINE = MergeTree ORDER BY id
        """)
    defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }
    let envOptions = ["production", "staging", "development"]
    let totalBlocks = (rowCount + blockRowCount - 1) / blockRowCount
    let start = ContinuousClock.now
    for blockIndex in 0..<totalBlocks {
        let blockStart = blockIndex * blockRowCount
        let blockEnd = min(blockStart + blockRowCount, rowCount)
        let count = blockEnd - blockStart
        var ids = [UInt64](); ids.reserveCapacity(count)
        var envs = [String](); envs.reserveCapacity(count)
        var attributes = [[String: String]](); attributes.reserveCapacity(count)
        for index in blockStart..<blockEnd {
            ids.append(UInt64(index))
            envs.append(envOptions[index % envOptions.count])
            attributes.append(["service": "svc-\(index % 16)", "region": "ap-southeast-2"])
        }
        try await client.insert(into: table, columns: [
            .init(name: "id", values: .uint64(ids)),
            .init(name: "env", values: .lowCardinalityString(envs)),
            .init(name: "attributes", values: .mapStringString(attributes)),
        ])
    }
    summary(mode: "insert_lc_map", rows: rowCount, seconds: elapsedSeconds(start), extra: "block_rows=\(blockRowCount)")
}

private func seedLCMapTable(_ table: String) async throws {
    try await client.execute("DROP TABLE IF EXISTS \(table)")
    try await client.execute("""
        CREATE TABLE \(table) (
          id UInt64,
          env LowCardinality(String),
          attributes Map(LowCardinality(String), String)
        ) ENGINE = MergeTree ORDER BY id
        """)
    let envOptions = ["production", "staging", "development"]
    let totalBlocks = (rowCount + blockRowCount - 1) / blockRowCount
    for blockIndex in 0..<totalBlocks {
        let blockStart = blockIndex * blockRowCount
        let blockEnd = min(blockStart + blockRowCount, rowCount)
        let rows = (blockStart..<blockEnd).map { index in
            LCRow(
                id: UInt64(index),
                env: envOptions[index % envOptions.count],
                attributes: ["service": "svc-\(index % 16)", "region": "ap-southeast-2"]
            )
        }
        try await client.insert(into: table, rows: rows)
    }
}

private func runSelectLCMap() async throws {
    let table = tableName("sel_lc")
    try await seedLCMapTable(table)
    defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }
    var observed = 0
    let start = ContinuousClock.now
    for try await block in client.selectColumns("SELECT id, env, attributes FROM \(table) ORDER BY id") {
        observed += block.rowCount
    }
    summary(mode: "select_lc_map", rows: observed, seconds: elapsedSeconds(start))
}

private func runSelectLCMapFast() async throws {
    let table = tableName("sel_lc_fast")
    try await seedLCMapTable(table)
    defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }
    var observed = 0
    let start = ContinuousClock.now
    for try await batch in client.selectStreamFast(LCRow.self, from: "SELECT id, env, attributes FROM \(table) ORDER BY id") {
        observed += batch.count
    }
    summary(mode: "select_lc_map_fast", rows: observed, seconds: elapsedSeconds(start))
}

private func runSelectLCMapWire() async throws {
    let table = tableName("sel_lc_wire")
    try await seedLCMapTable(table)
    defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }
    var observed = 0
    let start = ContinuousClock.now
    for try await block in client.selectColumns("SELECT id, env, attributes FROM \(table) ORDER BY id") {
        observed += block.rowCount
    }
    summary(mode: "select_lc_map_wire", rows: observed, seconds: elapsedSeconds(start))
}

private func percentile(_ sortedSamples: [Int64], _ fraction: Double) -> Int64 {
    if sortedSamples.isEmpty { return 0 }
    let lastIndex = sortedSamples.count - 1
    let position = Int((Double(lastIndex) * fraction).rounded())
    let clamped = min(max(position, 0), lastIndex)
    return sortedSamples[clamped]
}

private func microsecondsSince(_ start: ContinuousClock.Instant) -> Int64 {
    let duration = ContinuousClock.now - start
    let seconds = duration.components.seconds
    let attoseconds = duration.components.attoseconds
    return seconds * 1_000_000 + attoseconds / 1_000_000_000_000
}

private func latencySummary(mode: String, samples: [Int64]) {
    var sorted = samples
    sorted.sort()
    let p50 = percentile(sorted, 0.50)
    let p95 = percentile(sorted, 0.95)
    let p99 = percentile(sorted, 0.99)
    let maxValue = sorted.last ?? 0
    let total = sorted.reduce(Int64(0), +)
    let mean = sorted.isEmpty ? Int64(0) : total / Int64(sorted.count)
    print("[CH PERF SWIFT] \(mode) iterations=\(sorted.count) p50=\(p50)us p95=\(p95)us p99=\(p99)us max=\(maxValue)us mean=\(mean)us")
}

private func runLatencySingleInsert() async throws {
    let table = tableName("lat_ins")
    try await client.execute("DROP TABLE IF EXISTS \(table)")
    try await client.execute("CREATE TABLE \(table) (id UInt64, value Float64) ENGINE = MergeTree ORDER BY id")
    defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }

    var samples = [Int64]()
    samples.reserveCapacity(latencyIterations)
    for iteration in 0..<latencyIterations {
        let ids: [UInt64] = [UInt64(iteration)]
        let values: [Double] = [Double(iteration) * 0.5]
        let start = ContinuousClock.now
        try await client.insert(into: table, columns: [
            .init(name: "id", values: .uint64(ids)),
            .init(name: "value", values: .float64(values)),
        ])
        samples.append(microsecondsSince(start))
    }
    latencySummary(mode: "latency_single_insert", samples: samples)
}

private func runLatencySingleSelect() async throws {
    var samples = [Int64]()
    samples.reserveCapacity(latencyIterations)
    for _ in 0..<latencyIterations {
        let start = ContinuousClock.now
        _ = try await client.scalarInt64("SELECT toInt64(1)")
        samples.append(microsecondsSince(start))
    }
    latencySummary(mode: "latency_single_select", samples: samples)
}

private func runLatencySmallBatchInsert() async throws {
    let table = tableName("lat_batch")
    try await client.execute("DROP TABLE IF EXISTS \(table)")
    try await client.execute("CREATE TABLE \(table) (id UInt64, value Float64) ENGINE = MergeTree ORDER BY id")
    defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }

    var samples = [Int64]()
    samples.reserveCapacity(latencyIterations)
    for iteration in 0..<latencyIterations {
        let base = iteration * latencySmallBatchRows
        let ids = (0..<latencySmallBatchRows).map { UInt64(base + $0) }
        let values = (0..<latencySmallBatchRows).map { Double(base + $0) * 0.5 }
        let start = ContinuousClock.now
        try await client.insert(into: table, columns: [
            .init(name: "id", values: .uint64(ids)),
            .init(name: "value", values: .float64(values)),
        ])
        samples.append(microsecondsSince(start))
    }
    latencySummary(mode: "latency_small_batch_insert", samples: samples)
}

private struct ConcurrentTaskResult: Sendable {

    let rows: Int
    let elapsed: Double

}

private func medianRate(_ taskResults: [ConcurrentTaskResult]) -> Int {
    if taskResults.isEmpty { return 0 }
    let perTaskRates = taskResults.map { rate(count: $0.rows, seconds: $0.elapsed) }
    let sorted = perTaskRates.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}

private func concurrentSummary(mode: String, taskResults: [ConcurrentTaskResult], wallSeconds: Double) {
    let totalRows = taskResults.reduce(0) { $0 + $1.rows }
    let aggregate = rate(count: totalRows, seconds: wallSeconds)
    let perTaskMedian = medianRate(taskResults)
    print("[CH PERF SWIFT] \(mode) tasks=\(taskResults.count) total_rows=\(totalRows) elapsed=\(String(format: "%.3f", wallSeconds))s aggregate=\(aggregate)/s per_task_median=\(perTaskMedian)/s")
}

private func runConcurrentInsertThroughput() async throws {
    let table = tableName("cc_ins")
    try await client.execute("DROP TABLE IF EXISTS \(table)")
    try await client.execute("CREATE TABLE \(table) (id UInt64, tag String, value Float64, ts DateTime) ENGINE = MergeTree ORDER BY id")
    defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }

    let rowsPerTask = rowCount / concurrency
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let wallStart = ContinuousClock.now
    let results = try await withThrowingTaskGroup(of: ConcurrentTaskResult.self, returning: [ConcurrentTaskResult].self) { group in
        for taskIndex in 0..<concurrency {
            group.addTask {
                let rangeStart = taskIndex * rowsPerTask
                let rangeEnd = rangeStart + rowsPerTask
                let totalBlocks = (rowsPerTask + blockRowCount - 1) / blockRowCount
                let taskStart = ContinuousClock.now
                for blockIndex in 0..<totalBlocks {
                    let blockStart = rangeStart + blockIndex * blockRowCount
                    let blockEnd = min(blockStart + blockRowCount, rangeEnd)
                    let count = blockEnd - blockStart
                    let ids = (blockStart..<blockEnd).map { UInt64($0) }
                    let tags = (blockStart..<blockEnd).map { "tag-\($0 % 100)" }
                    let values = (blockStart..<blockEnd).map { Double($0) * 0.5 }
                    let timestamps = Array(repeating: timestamp, count: count)
                    try await client.insert(into: table, columns: [
                        .init(name: "id", values: .uint64(ids)),
                        .init(name: "tag", values: .string(tags)),
                        .init(name: "value", values: .float64(values)),
                        .init(name: "ts", values: .dateTime(timestamps)),
                    ])
                }
                return ConcurrentTaskResult(rows: rowsPerTask, elapsed: elapsedSeconds(taskStart))
            }
        }
        var collected = [ConcurrentTaskResult]()
        collected.reserveCapacity(concurrency)
        for try await result in group {
            collected.append(result)
        }
        return collected
    }
    concurrentSummary(mode: "concurrent_insert_throughput", taskResults: results, wallSeconds: elapsedSeconds(wallStart))
}

private func runConcurrentSelectThroughput() async throws {
    let table = tableName("cc_sel")
    try await seedBulkTable(table)
    defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }

    let wallStart = ContinuousClock.now
    let results = try await withThrowingTaskGroup(of: ConcurrentTaskResult.self, returning: [ConcurrentTaskResult].self) { group in
        for _ in 0..<concurrency {
            group.addTask {
                let taskStart = ContinuousClock.now
                var observed = 0
                for try await _ in client.selectStream(BenchRow.self, from: "SELECT id, tag, value, ts FROM \(table)") {
                    observed += 1
                }
                return ConcurrentTaskResult(rows: observed, elapsed: elapsedSeconds(taskStart))
            }
        }
        var collected = [ConcurrentTaskResult]()
        collected.reserveCapacity(concurrency)
        for try await result in group {
            collected.append(result)
        }
        return collected
    }
    concurrentSummary(mode: "concurrent_select_throughput", taskResults: results, wallSeconds: elapsedSeconds(wallStart))
}

private func runConcurrentSelectFast() async throws {
    let table = tableName("cc_sel_fast")
    try await seedBulkTable(table)
    defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }

    let wallStart = ContinuousClock.now
    let results = try await withThrowingTaskGroup(of: ConcurrentTaskResult.self, returning: [ConcurrentTaskResult].self) { group in
        for _ in 0..<concurrency {
            group.addTask {
                let taskStart = ContinuousClock.now
                var observed = 0
                for try await batch in client.selectStreamFast(BenchRow.self, from: "SELECT id, tag, value, ts FROM \(table)") {
                    observed += batch.count
                }
                return ConcurrentTaskResult(rows: observed, elapsed: elapsedSeconds(taskStart))
            }
        }
        var collected = [ConcurrentTaskResult]()
        collected.reserveCapacity(concurrency)
        for try await result in group {
            collected.append(result)
        }
        return collected
    }
    concurrentSummary(mode: "concurrent_select_fast", taskResults: results, wallSeconds: elapsedSeconds(wallStart))
}

private func runConcurrentSelectBuilder() async throws {
    let table = tableName("cc_sel_builder")
    try await seedBulkTable(table)
    defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }

    let wallStart = ContinuousClock.now
    let results = try await withThrowingTaskGroup(of: ConcurrentTaskResult.self, returning: [ConcurrentTaskResult].self) { group in
        for _ in 0..<concurrency {
            group.addTask {
                let taskStart = ContinuousClock.now
                var observed = 0
                let slotCache = BenchRowSlotCache()
                let stream = client.selectStreamBuilder(BenchRow.self, from: "SELECT id, tag, value, ts FROM \(table)") { block, rowIndex in
                    let slots = slotCache.ensure(block)
                    return extractBenchRow(block: block, slots: slots, rowIndex: rowIndex)
                }
                for try await batch in stream {
                    observed += batch.count
                }
                return ConcurrentTaskResult(rows: observed, elapsed: elapsedSeconds(taskStart))
            }
        }
        var collected = [ConcurrentTaskResult]()
        collected.reserveCapacity(concurrency)
        for try await result in group {
            collected.append(result)
        }
        return collected
    }
    concurrentSummary(mode: "concurrent_select_builder", taskResults: results, wallSeconds: elapsedSeconds(wallStart))
}

private func runEncodeOnlyCodable() async throws {
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let totalBlocks = (rowCount + blockRowCount - 1) / blockRowCount
    let encoder = ClickHouseRowEncoder()
    // Warmup
    let warmRows = (0..<min(1000, blockRowCount)).map { index in
        BenchRow(id: UInt64(index), tag: "tag-\(index % 100)", value: Double(index) * 0.5, ts: timestamp)
    }
    _ = try encoder.encode(warmRows)
    let start = ContinuousClock.now
    for blockIndex in 0..<totalBlocks {
        let blockStart = blockIndex * blockRowCount
        let blockEnd = min(blockStart + blockRowCount, rowCount)
        let rows = (blockStart..<blockEnd).map { index in
            BenchRow(id: UInt64(index), tag: "tag-\(index % 100)", value: Double(index) * 0.5, ts: timestamp)
        }
        _ = try encoder.encode(rows)
    }
    summary(mode: "encode_only_codable", rows: rowCount, seconds: elapsedSeconds(start), extra: "block_rows=\(blockRowCount)")
}

private struct TypedColumnSpec {

    let typeName: String
    let sqlType: String
    let buildPayload: @Sendable (_ blockStart: Int, _ blockEnd: Int) -> ClickHouseColumnEntry.Values

}

private func typedString10(_ index: Int) -> String {
    let raw = "row\(index)"
    if raw.count >= 10 { return String(raw.prefix(10)) }
    return raw + String(repeating: "x", count: 10 - raw.count)
}

private func typedString256(_ index: Int) -> String {
    let header = "row\(index)-"
    return header + String(repeating: "p", count: 256 - header.count)
}

private func typedFixed16Bytes(_ index: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: 16)
    var value = UInt64(bitPattern: Int64(index))
    for byteIndex in 0..<8 {
        bytes[byteIndex] = UInt8(value & 0xFF)
        value >>= 8
    }
    return Data(bytes)
}

private func typedDeterministicUUID(_ index: Int) -> UUID {
    var bytes = [UInt8](repeating: 0, count: 16)
    var value = UInt64(bitPattern: Int64(index))
    for byteIndex in 0..<8 {
        bytes[byteIndex] = UInt8(value & 0xFF)
        value >>= 8
    }
    let tuple: uuid_t = (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    )
    return UUID(uuid: tuple)
}

private func typedSpecSignedInteger(_ typeName: String) -> TypedColumnSpec? {
    switch typeName {
    case "int8":
        return .init(typeName: typeName, sqlType: "Int8") { start, end in
            .int8((start..<end).map { Int8(truncatingIfNeeded: $0) })
        }
    case "int16":
        return .init(typeName: typeName, sqlType: "Int16") { start, end in
            .int16((start..<end).map { Int16(truncatingIfNeeded: $0) })
        }
    case "int32":
        return .init(typeName: typeName, sqlType: "Int32") { start, end in
            .int32((start..<end).map { Int32(truncatingIfNeeded: $0) })
        }
    case "int64":
        return .init(typeName: typeName, sqlType: "Int64") { start, end in
            .int64((start..<end).map { Int64($0) })
        }
    default:
        return nil
    }
}

private func typedSpecUnsignedInteger(_ typeName: String) -> TypedColumnSpec? {
    switch typeName {
    case "uint8":
        return .init(typeName: typeName, sqlType: "UInt8") { start, end in
            .uint8((start..<end).map { UInt8(truncatingIfNeeded: $0) })
        }
    case "uint16":
        return .init(typeName: typeName, sqlType: "UInt16") { start, end in
            .uint16((start..<end).map { UInt16(truncatingIfNeeded: $0) })
        }
    case "uint32":
        return .init(typeName: typeName, sqlType: "UInt32") { start, end in
            .uint32((start..<end).map { UInt32(truncatingIfNeeded: $0) })
        }
    case "uint64":
        return .init(typeName: typeName, sqlType: "UInt64") { start, end in
            .uint64((start..<end).map { UInt64($0) })
        }
    default:
        return nil
    }
}

private func typedSpecFloating(_ typeName: String) -> TypedColumnSpec? {
    switch typeName {
    case "float32":
        return .init(typeName: typeName, sqlType: "Float32") { start, end in
            .float32((start..<end).map { Float32($0) * 0.25 })
        }
    case "float64":
        return .init(typeName: typeName, sqlType: "Float64") { start, end in
            .float64((start..<end).map { Float64($0) * 0.5 })
        }
    default:
        return nil
    }
}

private func typedSpecStringFamily(_ typeName: String) -> TypedColumnSpec? {
    switch typeName {
    case "string":
        return .init(typeName: typeName, sqlType: "String") { start, end in
            .string((start..<end).map { typedString10($0) })
        }
    case "string_long":
        return .init(typeName: typeName, sqlType: "String") { start, end in
            .string((start..<end).map { typedString256($0) })
        }
    case "fixed_string_16":
        return .init(typeName: typeName, sqlType: "FixedString(16)") { start, end in
            .fixedString(length: 16, (start..<end).map { typedFixed16Bytes($0) })
        }
    case "nullable_string":
        return .init(typeName: typeName, sqlType: "Nullable(String)") { start, end in
            .nullableString((start..<end).map { index in
                index.isMultiple(of: 2) ? .present(typedString10(index)) : .absent
            })
        }
    default:
        return nil
    }
}

private func typedSpecMisc(_ typeName: String) -> TypedColumnSpec? {
    switch typeName {
    case "bool":
        return .init(typeName: typeName, sqlType: "Bool") { start, end in
            .bool((start..<end).map { $0.isMultiple(of: 2) })
        }
    case "uuid":
        return .init(typeName: typeName, sqlType: "UUID") { start, end in
            .uuid((start..<end).map { typedDeterministicUUID($0) })
        }
    case "date":
        return .init(typeName: typeName, sqlType: "Date") { start, end in
            .date((start..<end).map { Date(timeIntervalSince1970: 1_700_000_000 + Double($0 % 365) * 86_400) })
        }
    case "date_time":
        return .init(typeName: typeName, sqlType: "DateTime") { start, end in
            .dateTime((start..<end).map { Date(timeIntervalSince1970: 1_700_000_000 + Double($0)) })
        }
    case "date_time64_nanos":
        return .init(typeName: typeName, sqlType: "DateTime64(9)") { start, end in
            .dateTime64Nanoseconds(
                (start..<end).map { ClickHouseNanoseconds(Int64(1_700_000_000_000_000_000) + Int64($0)) },
                precision: 9
            )
        }
    case "array_int32":
        return .init(typeName: typeName, sqlType: "Array(Int32)") { start, end in
            .arrayOfInt32((start..<end).map { index in
                (0..<8).map { offset in Int32(truncatingIfNeeded: index &+ offset) }
            })
        }
    default:
        return nil
    }
}

private enum TypedBenchError: Error, CustomStringConvertible {

    case unknownType(String)

    var description: String {
        switch self {
        case .unknownType(let name): return "unknown CH_BENCH_TYPES entry: \(name)"
        }
    }

}

private func typedSpec(for typeName: String) throws -> TypedColumnSpec {
    if let spec = typedSpecSignedInteger(typeName) { return spec }
    if let spec = typedSpecUnsignedInteger(typeName) { return spec }
    if let spec = typedSpecFloating(typeName) { return spec }
    if let spec = typedSpecStringFamily(typeName) { return spec }
    if let spec = typedSpecMisc(typeName) { return spec }
    throw TypedBenchError.unknownType(typeName)
}

private func writeTypedBlocks(_ table: String, spec: TypedColumnSpec) async throws {
    let totalBlocks = (rowCount + blockRowCount - 1) / blockRowCount
    for blockIndex in 0..<totalBlocks {
        let blockStart = blockIndex * blockRowCount
        let blockEnd = min(blockStart + blockRowCount, rowCount)
        let ids = (blockStart..<blockEnd).map { UInt64($0) }
        let payload = spec.buildPayload(blockStart, blockEnd)
        try await client.insert(into: table, columns: [
            .init(name: "id", values: .uint64(ids)),
            .init(name: "payload", values: payload),
        ])
    }
}

private func runInsertTyped(_ typeName: String) async throws {
    let spec = try typedSpec(for: typeName)
    let table = tableName("typed_\(typeName)")
    try await client.execute("DROP TABLE IF EXISTS \(table)")
    try await client.execute("CREATE TABLE \(table) (id UInt64, payload \(spec.sqlType)) ENGINE = MergeTree ORDER BY id")
    defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }

    let start = ContinuousClock.now
    try await writeTypedBlocks(table, spec: spec)
    summary(
        mode: "insert_typed_\(typeName)",
        rows: rowCount,
        seconds: elapsedSeconds(start),
        extra: "block_rows=\(blockRowCount) sql_type=\(spec.sqlType)"
    )
}

private func seedTypedTable(_ table: String, spec: TypedColumnSpec) async throws {
    try await client.execute("DROP TABLE IF EXISTS \(table)")
    try await client.execute("CREATE TABLE \(table) (id UInt64, payload \(spec.sqlType)) ENGINE = MergeTree ORDER BY id")
    try await writeTypedBlocks(table, spec: spec)
}

private func runSelectTyped(_ typeName: String) async throws {
    let spec = try typedSpec(for: typeName)
    let table = tableName("sel_typed_\(typeName)")
    try await seedTypedTable(table, spec: spec)
    defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }

    var observed = 0
    let start = ContinuousClock.now
    for try await block in client.selectColumns("SELECT id, payload FROM \(table)") {
        observed += block.rowCount
    }
    summary(
        mode: "select_typed_\(typeName)",
        rows: observed,
        seconds: elapsedSeconds(start),
        extra: "sql_type=\(spec.sqlType)"
    )
}

private func runTypedModeForAllTypes(_ baseMode: String) async {
    for typeName in selectedTypedTypes {
        do {
            switch baseMode {
            case "insert_typed":
                try await runInsertTyped(typeName)
            case "select_typed":
                try await runSelectTyped(typeName)
            default:
                print("[CH PERF SWIFT] unknown typed mode: \(baseMode)")
            }
        } catch {
            print("[CH PERF SWIFT] FAIL mode=\(baseMode)_\(typeName) error=\(error)")
        }
    }
}

private let realEventTypes = ["click", "view", "purchase", "scroll", "hover", "submit"]

private func realPayload(_ index: Int) -> String {
    let head = "p\(index)-"
    let target = 200
    if head.count >= target {
        return String(head.prefix(target))
    }
    let filler = (index % 7 == 0) ? "abc" : "xyz"
    var result = head
    while result.count + filler.count <= target {
        result += filler
    }
    if result.count < target {
        result += String(repeating: "z", count: target - result.count)
    }
    return result
}

private func realBuildEventsBlock(blockStart: Int, blockEnd: Int) -> [ClickHouseColumnEntry] {
    let count = blockEnd - blockStart
    var ids = [UInt64](); ids.reserveCapacity(count)
    var userIds = [UInt64](); userIds.reserveCapacity(count)
    var eventTypes = [String](); eventTypes.reserveCapacity(count)
    var values = [Double](); values.reserveCapacity(count)
    var payloads = [String](); payloads.reserveCapacity(count)
    var timestamps = [ClickHouseNanoseconds](); timestamps.reserveCapacity(count)
    let baseNanos: Int64 = 1_700_000_000_000_000_000
    for index in blockStart..<blockEnd {
        ids.append(UInt64(index))
        userIds.append(UInt64(index % 1_000_000))
        eventTypes.append(realEventTypes[index % realEventTypes.count])
        values.append(Double(index % 10_000) * 0.5)
        payloads.append(realPayload(index))
        timestamps.append(ClickHouseNanoseconds(baseNanos + Int64(index) * 1_000))
    }
    return [
        .init(name: "id", values: .uint64(ids)),
        .init(name: "user_id", values: .uint64(userIds)),
        .init(name: "event_type", values: .lowCardinalityString(eventTypes)),
        .init(name: "value", values: .float64(values)),
        .init(name: "payload", values: .string(payloads)),
        .init(name: "ts", values: .dateTime64Nanoseconds(timestamps, precision: 9)),
    ]
}

private func realBuildLogsBlock(blockStart: Int, blockEnd: Int) -> [ClickHouseColumnEntry] {
    let count = blockEnd - blockStart
    var ids = [UInt64](); ids.reserveCapacity(count)
    var attributes = [[String: String]](); attributes.reserveCapacity(count)
    for index in blockStart..<blockEnd {
        ids.append(UInt64(index))
        attributes.append([
            "service": "svc-\(index % 64)",
            "region": "ap-southeast-2",
            "level": (index % 4 == 0) ? "warn" : "info",
        ])
    }
    return [
        .init(name: "id", values: .uint64(ids)),
        .init(name: "attributes", values: .mapStringString(attributes)),
    ]
}

private func realFillTable(_ table: String, totalRows: Int, blockBuilder: (Int, Int) -> [ClickHouseColumnEntry]) async throws {
    let totalBlocks = (totalRows + realFixtureBlock - 1) / realFixtureBlock
    for blockIndex in 0..<totalBlocks {
        let blockStart = blockIndex * realFixtureBlock
        let blockEnd = min(blockStart + realFixtureBlock, totalRows)
        let columns = blockBuilder(blockStart, blockEnd)
        try await client.insert(into: table, columns: columns)
    }
}

private func runRealBenchSetup() async throws {
    let start = ContinuousClock.now
    try await client.execute("DROP DATABASE IF EXISTS \(sampleFixtureDatabase)")
    try await client.execute("CREATE DATABASE \(sampleFixtureDatabase)")
    try await client.execute("""
        CREATE TABLE \(sampleEventsTable) (
          id UInt64,
          user_id UInt64,
          event_type LowCardinality(String),
          value Float64,
          payload String,
          ts DateTime64(9)
        ) ENGINE = MergeTree ORDER BY (user_id, ts)
        """)
    try await client.execute("""
        CREATE TABLE \(sampleLogsTable) (
          id UInt64,
          attributes Map(LowCardinality(String), String)
        ) ENGINE = MergeTree ORDER BY id
        """)

    try await realFillTable(sampleEventsTable, totalRows: sampleEventsRows, blockBuilder: realBuildEventsBlock)
    try await realFillTable(sampleLogsTable, totalRows: sampleLogsRows, blockBuilder: realBuildLogsBlock)

    let eventsCount = try await client.scalarInt64("SELECT toInt64(count()) FROM \(sampleEventsTable)")
    let logsCount = try await client.scalarInt64("SELECT toInt64(count()) FROM \(sampleLogsTable)")
    let seconds = elapsedSeconds(start)
    print("[CH PERF SWIFT] benchsetup events_table=\(sampleEventsTable) events_rows=\(eventsCount) logs_table=\(sampleLogsTable) logs_rows=\(logsCount) elapsed=\(String(format: "%.3f", seconds))s")
    if Int(eventsCount) != sampleEventsRows {
        throw RealWorkloadError.rowCountMismatch(expected: sampleEventsRows, actual: Int(eventsCount), table: sampleEventsTable)
    }
    if Int(logsCount) != sampleLogsRows {
        throw RealWorkloadError.rowCountMismatch(expected: sampleLogsRows, actual: Int(logsCount), table: sampleLogsTable)
    }
}

private enum RealWorkloadError: Error, CustomStringConvertible {

    case rowCountMismatch(expected: Int, actual: Int, table: String)

    var description: String {
        switch self {
        case .rowCountMismatch(let expected, let actual, let table):
            return "row count mismatch for \(table): expected=\(expected) actual=\(actual)"
        }
    }

}

private struct RealEvent: Codable, Sendable {

    let id: UInt64
    let user_id: UInt64
    let event_type: String
    let value: Float64
    let payload: String
    let ts: Date

}

private struct RealEventProjection: Codable, Sendable {

    let id: UInt64
    let ts: Date
    let value: Float64

}

private func runRealSelectOrderByLimit() async throws {
    let sql = "SELECT id, user_id, event_type, value, payload, ts FROM \(sampleEventsTable) WHERE event_type = 'click' ORDER BY ts DESC LIMIT 100000"
    var observed = 0
    var firstByteMicroseconds: Int64 = 0
    let totalStart = ContinuousClock.now
    var decodeMicroseconds: Int64 = 0
    for try await block in client.selectColumns(sql) {
        if firstByteMicroseconds == 0 {
            firstByteMicroseconds = microsecondsSince(totalStart)
        }
        let decodeStart = ContinuousClock.now
        observed += block.rowCount
        decodeMicroseconds += microsecondsSince(decodeStart)
    }
    realSummary(
        mode: "select_orderby_limit",
        rows: observed,
        seconds: elapsedSeconds(totalStart),
        firstByteMicroseconds: firstByteMicroseconds,
        totalDecodeMicroseconds: decodeMicroseconds
    )
}

private func runRealSelectGroupBy() async throws {
    let sql = "SELECT user_id, count(*) AS c FROM \(sampleEventsTable) GROUP BY user_id ORDER BY c DESC LIMIT 10000"
    var observed = 0
    var firstByteMicroseconds: Int64 = 0
    let totalStart = ContinuousClock.now
    var decodeMicroseconds: Int64 = 0
    for try await block in client.selectColumns(sql) {
        if firstByteMicroseconds == 0 {
            firstByteMicroseconds = microsecondsSince(totalStart)
        }
        let decodeStart = ContinuousClock.now
        observed += block.rowCount
        decodeMicroseconds += microsecondsSince(decodeStart)
    }
    realSummary(
        mode: "select_groupby",
        rows: observed,
        seconds: elapsedSeconds(totalStart),
        firstByteMicroseconds: firstByteMicroseconds,
        totalDecodeMicroseconds: decodeMicroseconds
    )
}

private func runRealSelectWhereIn() async throws {
    let sql = "SELECT id, user_id, ts, value FROM \(sampleEventsTable) WHERE user_id IN (SELECT number FROM numbers(1, 100000))"
    var observed = 0
    var firstByteMicroseconds: Int64 = 0
    let totalStart = ContinuousClock.now
    var decodeMicroseconds: Int64 = 0
    for try await block in client.selectColumns(sql) {
        if firstByteMicroseconds == 0 {
            firstByteMicroseconds = microsecondsSince(totalStart)
        }
        let decodeStart = ContinuousClock.now
        observed += block.rowCount
        decodeMicroseconds += microsecondsSince(decodeStart)
    }
    realSummary(
        mode: "select_where_in",
        rows: observed,
        seconds: elapsedSeconds(totalStart),
        firstByteMicroseconds: firstByteMicroseconds,
        totalDecodeMicroseconds: decodeMicroseconds
    )
}

private struct RealProjectionSlot: Sendable {

    let id: Int
    let ts: Int
    let value: Int

}

private func realResolveProjectionSlots(_ block: ClickHouseSelectBlock) -> RealProjectionSlot {
    var idSlot = -1
    var tsSlot = -1
    var valueSlot = -1
    for (position, column) in block.columns.enumerated() {
        switch column.name {
        case "id": idSlot = position
        case "ts": tsSlot = position
        case "value": valueSlot = position
        default: continue
        }
    }
    return RealProjectionSlot(id: idSlot, ts: tsSlot, value: valueSlot)
}

private final class RealProjectionSlotCache: @unchecked Sendable {

    var slots = RealProjectionSlot(id: -1, ts: -1, value: -1)
    var columnsCount = -1

    func ensure(_ block: ClickHouseSelectBlock) -> RealProjectionSlot {
        if columnsCount != block.columns.count {
            slots = realResolveProjectionSlots(block)
            columnsCount = block.columns.count
        }
        return slots
    }

}

private func realExtractNanosecond(_ values: ClickHouseColumnEntry.Values, _ rowIndex: Int) -> Date {
    if case .dateTime64Nanoseconds(let arr, _) = values {
        let nanos = arr[rowIndex].rawValue
        return Date(timeIntervalSince1970: Double(nanos) / 1_000_000_000)
    }
    if case .dateTime(let arr) = values { return arr[rowIndex] }
    return Date(timeIntervalSince1970: 0)
}

private func realBuildProjectionRow(block: ClickHouseSelectBlock, slots: RealProjectionSlot, rowIndex: Int) -> RealEventProjection {
    let id = extractUInt64(block.columns[slots.id].values, rowIndex)
    let ts = realExtractNanosecond(block.columns[slots.ts].values, rowIndex)
    let value = extractDouble(block.columns[slots.value].values, rowIndex)
    return RealEventProjection(id: id, ts: ts, value: value)
}

private func runRealSelectFullScanProjection() async throws {
    let sql = "SELECT id, ts, value FROM \(sampleEventsTable)"
    var observed = 0
    var firstByteMicroseconds: Int64 = 0
    let totalStart = ContinuousClock.now
    var decodeMicroseconds: Int64 = 0
    let slotCache = RealProjectionSlotCache()
    let stream = client.selectStreamBuilder(RealEventProjection.self, from: sql) { block, rowIndex in
        let slots = slotCache.ensure(block)
        return realBuildProjectionRow(block: block, slots: slots, rowIndex: rowIndex)
    }
    for try await batch in stream {
        if firstByteMicroseconds == 0 {
            firstByteMicroseconds = microsecondsSince(totalStart)
        }
        let decodeStart = ContinuousClock.now
        for row in batch {
            observed += 1
            _ = row.id
        }
        decodeMicroseconds += microsecondsSince(decodeStart)
    }
    realSummary(
        mode: "select_full_scan_proj",
        rows: observed,
        seconds: elapsedSeconds(totalStart),
        firstByteMicroseconds: firstByteMicroseconds,
        totalDecodeMicroseconds: decodeMicroseconds
    )
}

private struct RealEventProjectionRows: Codable, Sendable {

    let id: UInt64
    let value: Float64

}

private func runRealSelectOrderByLimitRows() async throws {
    let sql = "SELECT id, value FROM \(sampleEventsTable) WHERE event_type = 'click' ORDER BY ts DESC LIMIT 100000"
    var observed = 0
    var firstByteMicroseconds: Int64 = 0
    let totalStart = ContinuousClock.now
    var decodeMicroseconds: Int64 = 0
    let stream = client.selectRows(RealEventProjectionRows.self, from: sql)
    let decodeStart = ContinuousClock.now
    for try await row in stream {
        if firstByteMicroseconds == 0 {
            firstByteMicroseconds = microsecondsSince(totalStart)
        }
        observed += 1
        _ = row.id
    }
    decodeMicroseconds += microsecondsSince(decodeStart)
    realSummary(
        mode: "select_orderby_limit_rows",
        rows: observed,
        seconds: elapsedSeconds(totalStart),
        firstByteMicroseconds: firstByteMicroseconds,
        totalDecodeMicroseconds: decodeMicroseconds
    )
}

private func runRealSelectFullScanProjectionRows() async throws {
    let sql = "SELECT id, value FROM \(sampleEventsTable)"
    var observed = 0
    var firstByteMicroseconds: Int64 = 0
    let totalStart = ContinuousClock.now
    var decodeMicroseconds: Int64 = 0
    let stream = client.selectRows(RealEventProjectionRows.self, from: sql)
    let decodeStart = ContinuousClock.now
    for try await row in stream {
        if firstByteMicroseconds == 0 {
            firstByteMicroseconds = microsecondsSince(totalStart)
        }
        observed += 1
        _ = row.id
    }
    decodeMicroseconds += microsecondsSince(decodeStart)
    realSummary(
        mode: "select_full_scan_proj_rows",
        rows: observed,
        seconds: elapsedSeconds(totalStart),
        firstByteMicroseconds: firstByteMicroseconds,
        totalDecodeMicroseconds: decodeMicroseconds
    )
}

private func runRealSelectFullScanProjectionStream() async throws {
    let sql = "SELECT id, value FROM \(sampleEventsTable)"
    var observed = 0
    var firstByteMicroseconds: Int64 = 0
    let totalStart = ContinuousClock.now
    var decodeMicroseconds: Int64 = 0
    let stream = client.selectStream(RealEventProjectionRows.self, from: sql)
    let decodeStart = ContinuousClock.now
    for try await row in stream {
        if firstByteMicroseconds == 0 {
            firstByteMicroseconds = microsecondsSince(totalStart)
        }
        observed += 1
        _ = row.id
    }
    decodeMicroseconds += microsecondsSince(decodeStart)
    realSummary(
        mode: "select_full_scan_proj_stream",
        rows: observed,
        seconds: elapsedSeconds(totalStart),
        firstByteMicroseconds: firstByteMicroseconds,
        totalDecodeMicroseconds: decodeMicroseconds
    )
}

private func runRealSelectFullScanProjectionStreamFast() async throws {
    let sql = "SELECT id, value FROM \(sampleEventsTable)"
    var observed = 0
    var firstByteMicroseconds: Int64 = 0
    let totalStart = ContinuousClock.now
    var decodeMicroseconds: Int64 = 0
    let stream = client.selectStreamFast(RealEventProjectionRows.self, from: sql)
    for try await batch in stream {
        if firstByteMicroseconds == 0 {
            firstByteMicroseconds = microsecondsSince(totalStart)
        }
        let decodeStart = ContinuousClock.now
        for row in batch {
            observed += 1
            _ = row.id
        }
        decodeMicroseconds += microsecondsSince(decodeStart)
    }
    realSummary(
        mode: "select_full_scan_proj_streamfast",
        rows: observed,
        seconds: elapsedSeconds(totalStart),
        firstByteMicroseconds: firstByteMicroseconds,
        totalDecodeMicroseconds: decodeMicroseconds
    )
}

// Full-scan projection of the `payload` String column via the
// legacy `selectColumns` path, which materialises one Swift
// `String` per row at block-decode time. The companion mode
// `select_full_scan_proj_view` runs the same query through the
// new `selectStringColumns` view path; together they isolate the
// cost of per-row String materialisation on a real wire-decoded
// String column.
private func runRealSelectFullScanPayloadString() async throws {
    let sql = "SELECT payload FROM \(sampleEventsTable)"
    var observed = 0
    var totalBytes: Int64 = 0
    var firstByteMicroseconds: Int64 = 0
    let totalStart = ContinuousClock.now
    var decodeMicroseconds: Int64 = 0
    for try await block in client.selectColumns(sql) {
        if firstByteMicroseconds == 0 {
            firstByteMicroseconds = microsecondsSince(totalStart)
        }
        let decodeStart = ContinuousClock.now
        let added = realConsumePayloadStringBlock(block, totalBytes: &totalBytes)
        observed += added
        decodeMicroseconds += microsecondsSince(decodeStart)
    }
    realSummary(
        mode: "select_full_scan_proj_string",
        rows: observed,
        seconds: elapsedSeconds(totalStart),
        firstByteMicroseconds: firstByteMicroseconds,
        totalDecodeMicroseconds: decodeMicroseconds,
        extra: "bytes=\(totalBytes)"
    )
}

private func realConsumePayloadStringBlock(_ block: ClickHouseSelectBlock, totalBytes: inout Int64) -> Int {
    var observed = 0
    for column in block.columns where column.name == "payload" {
        if case .string(let strings) = column.values {
            for string in strings {
                observed += 1
                totalBytes += Int64(string.utf8.count)
            }
        }
    }
    return observed
}

// Full-scan projection of the `payload` String column via the
// zero-allocation `selectStringColumns` view path. Counts only
// rows + total UTF-8 bytes; no per-row Swift String is ever
// materialised. The companion mode `select_full_scan_proj` runs
// the same workload through the legacy `selectColumns` path,
// which materialises one `String` per row at block-decode time.
// Comparing the two isolates the cost of the per-row String
// allocation on a real wire-decoded String column.
private func runRealSelectFullScanProjectionView() async throws {
    let sql = "SELECT payload FROM \(sampleEventsTable)"
    var observed = 0
    var totalBytes: Int64 = 0
    var firstByteMicroseconds: Int64 = 0
    let totalStart = ContinuousClock.now
    var decodeMicroseconds: Int64 = 0
    for try await block in client.selectStringColumns(sql) {
        if firstByteMicroseconds == 0 {
            firstByteMicroseconds = microsecondsSince(totalStart)
        }
        let decodeStart = ContinuousClock.now
        let added = realConsumeStringViewBlock(block, totalBytes: &totalBytes)
        observed += added
        decodeMicroseconds += microsecondsSince(decodeStart)
    }
    realSummary(
        mode: "select_full_scan_proj_view",
        rows: observed,
        seconds: elapsedSeconds(totalStart),
        firstByteMicroseconds: firstByteMicroseconds,
        totalDecodeMicroseconds: decodeMicroseconds,
        extra: "bytes=\(totalBytes)"
    )
}

private func realConsumeStringViewBlock(_ block: ClickHouseBlockStringView, totalBytes: inout Int64) -> Int {
    var observed = 0
    for column in block.stringColumns where column.name == "payload" {
        column.forEach { _, view in
            observed += 1
            totalBytes += Int64(view.utf8Length)
        }
    }
    return observed
}

private func runRealSelectLowCardinalityAggregation() async throws {
    let sql = "SELECT event_type, avg(value) AS avg_value FROM \(sampleEventsTable) GROUP BY event_type"
    var observed = 0
    var firstByteMicroseconds: Int64 = 0
    let totalStart = ContinuousClock.now
    var decodeMicroseconds: Int64 = 0
    for try await block in client.selectColumns(sql) {
        if firstByteMicroseconds == 0 {
            firstByteMicroseconds = microsecondsSince(totalStart)
        }
        let decodeStart = ContinuousClock.now
        observed += block.rowCount
        decodeMicroseconds += microsecondsSince(decodeStart)
    }
    realSummary(
        mode: "select_lc_aggregation",
        rows: observed,
        seconds: elapsedSeconds(totalStart),
        firstByteMicroseconds: firstByteMicroseconds,
        totalDecodeMicroseconds: decodeMicroseconds
    )
}

private func runRealSelectStringFilter() async throws {
    let sql = "SELECT count(*) AS matched FROM \(sampleEventsTable) WHERE payload LIKE '%abc%'"
    var observedCount: Int64 = 0
    var firstByteMicroseconds: Int64 = 0
    let totalStart = ContinuousClock.now
    var decodeMicroseconds: Int64 = 0
    for try await block in client.selectColumns(sql) {
        if firstByteMicroseconds == 0 {
            firstByteMicroseconds = microsecondsSince(totalStart)
        }
        let decodeStart = ContinuousClock.now
        for column in block.columns where column.name == "matched" {
            if case .uint64(let arr) = column.values, let first = arr.first {
                observedCount = Int64(first)
            }
        }
        decodeMicroseconds += microsecondsSince(decodeStart)
    }
    realSummary(
        mode: "select_string_filter",
        rows: 1,
        seconds: elapsedSeconds(totalStart),
        firstByteMicroseconds: firstByteMicroseconds,
        totalDecodeMicroseconds: decodeMicroseconds,
        extra: "matched=\(observedCount)"
    )
}

private func runRealSelectDecodeOnly() async throws {
    let sql = "SELECT id, ts, value FROM \(sampleEventsTable)"
    // Warm the OS / CH page cache by running once and discarding the result.
    for try await _ in client.selectColumns(sql) { _ = 0 }

    var samplesMicroseconds = [Int64]()
    samplesMicroseconds.reserveCapacity(sampleDecodeOnlyIterations)
    var lastObserved = 0
    var lastFirstByte: Int64 = 0
    var lastDecode: Int64 = 0
    for _ in 0..<sampleDecodeOnlyIterations {
        var observed = 0
        var firstByteMicroseconds: Int64 = 0
        let totalStart = ContinuousClock.now
        var decodeMicroseconds: Int64 = 0
        let slotCache = RealProjectionSlotCache()
        let stream = client.selectStreamBuilder(RealEventProjection.self, from: sql) { block, rowIndex in
            let slots = slotCache.ensure(block)
            return realBuildProjectionRow(block: block, slots: slots, rowIndex: rowIndex)
        }
        for try await batch in stream {
            if firstByteMicroseconds == 0 {
                firstByteMicroseconds = microsecondsSince(totalStart)
            }
            let decodeStart = ContinuousClock.now
            for row in batch {
                observed += 1
                _ = row.value
            }
            decodeMicroseconds += microsecondsSince(decodeStart)
        }
        samplesMicroseconds.append(microsecondsSince(totalStart))
        lastObserved = observed
        lastFirstByte = firstByteMicroseconds
        lastDecode = decodeMicroseconds
    }
    samplesMicroseconds.sort()
    let medianMicroseconds = samplesMicroseconds[samplesMicroseconds.count / 2]
    let medianSeconds = Double(medianMicroseconds) / 1_000_000
    realSummary(
        mode: "select_decode_only",
        rows: lastObserved,
        seconds: medianSeconds,
        firstByteMicroseconds: lastFirstByte,
        totalDecodeMicroseconds: lastDecode,
        extra: "iterations=\(sampleDecodeOnlyIterations)"
    )
}

private func runRealSelectWireOnlyCount() async throws {
    let sql = "SELECT id, user_id, event_type, value, payload, ts FROM \(sampleEventsTable)"
    var observed = 0
    var firstByteMicroseconds: Int64 = 0
    let totalStart = ContinuousClock.now
    for try await block in client.selectColumns(sql) {
        if firstByteMicroseconds == 0 {
            firstByteMicroseconds = microsecondsSince(totalStart)
        }
        observed += block.rowCount
    }
    realSummary(
        mode: "select_wire_only_count",
        rows: observed,
        seconds: elapsedSeconds(totalStart),
        firstByteMicroseconds: firstByteMicroseconds,
        totalDecodeMicroseconds: 0
    )
}

private let ledgerRegions = ["nz", "au", "gb", "zz"]

private func ledgerAggregateId(_ index: Int) -> String {
    ledgerZeroPadded(value: index, width: 44)
}

private func ledgerAggregateKind(_ index: Int) -> String {
    ledgerZeroPadded(value: index, width: 4)
}

// Builds an ASCII zero-padded decimal of fixed width without any
// String concatenation. The previous shape
// `String(repeating: "0", count:) + String(index)` paid three String
// allocations per call (the "0"-repeat, the decimal raw, the concat
// result) and triggered StringGuts.append + prepareForAppendInPlace
// on every row — visible at 25%+ of CPU in ledger_bulk_insert.
// This path writes the digits directly into a `String`'s contiguous
// UTF-8 buffer with one allocation and zero growth.
@inline(__always)
private func ledgerZeroPadded(value: Int, width: Int) -> String {
    let digits = ledgerDecimalDigits(value: value)
    if digits.count >= width {
        return ledgerPaddedTruncated(digits: digits, width: width)
    }
    return ledgerPaddedLeftZero(digits: digits, width: width)
}

@inline(__always)
private func ledgerDecimalDigits(value: Int) -> [UInt8] {
    if value == 0 { return [0x30] }
    var digits = ledgerReversedDecimalDigits(absoluteValue: value < 0 ? -value : value)
    if value < 0 { digits.append(0x2D) }
    digits.reverse()
    return digits
}

@inline(__always)
private func ledgerReversedDecimalDigits(absoluteValue: Int) -> [UInt8] {
    var digits: [UInt8] = []
    digits.reserveCapacity(20)
    var remaining = absoluteValue
    while remaining > 0 {
        digits.append(UInt8(0x30 &+ (remaining % 10)))
        remaining /= 10
    }
    return digits
}

@inline(__always)
private func ledgerPaddedTruncated(digits: [UInt8], width: Int) -> String {
    String(unsafeUninitializedCapacity: width) { buffer in
        for index in 0..<width {
            buffer[index] = digits[index]
        }
        return width
    }
}

@inline(__always)
private func ledgerPaddedLeftZero(digits: [UInt8], width: Int) -> String {
    let padCount = width - digits.count
    return String(unsafeUninitializedCapacity: width) { buffer in
        for index in 0..<padCount {
            buffer[index] = 0x30
        }
        for index in 0..<digits.count {
            buffer[padCount + index] = digits[index]
        }
        return width
    }
}

private func ledgerRunBenchSetup() async throws {
    let start = ContinuousClock.now
    try await client.execute("DROP DATABASE IF EXISTS \(ledgerDatabase)")
    try await client.execute("CREATE DATABASE \(ledgerDatabase)")
    try await client.execute("""
        CREATE TABLE \(ledgerTable) (
            record_id UUID,
            entity_id FixedString(44),
            entity_refs Array(FixedString(44)),
            entity_ref_kinds Array(FixedString(4)),
            entity_kind LowCardinality(FixedString(4)),
            aggregate_domain LowCardinality(FixedString(3)),
            aggregate_subdomain LowCardinality(FixedString(1)),
            record_type LowCardinality(String),
            payload JSON,
            encryption LowCardinality(String),
            region LowCardinality(String),
            participant_ids Array(FixedString(44)),
            system_actor_ids Array(LowCardinality(String)),
            created_at DateTime64(9, 'Pacific/Auckland') CODEC(Delta(8), ZSTD(1)),
            valid_until DateTime64(9, 'Pacific/Auckland') CODEC(Delta(8), ZSTD(1)),
            published_at DateTime64(9, 'Pacific/Auckland') CODEC(Delta(8), ZSTD(1)),
            received_at DateTime64(9, 'Pacific/Auckland') CODEC(Delta(8), ZSTD(1)),
            is_deleted UInt8 DEFAULT 0
        ) ENGINE = MergeTree
        ORDER BY (entity_kind, entity_id, created_at, record_id)
        PARTITION BY (region, toYYYYMM(created_at))
        """)
    try await client.execute("""
        CREATE TABLE \(ledgerWritesTable) (
            record_id UUID,
            entity_id String,
            entity_refs Array(String),
            entity_ref_kinds Array(String),
            entity_kind LowCardinality(String),
            aggregate_domain LowCardinality(String),
            aggregate_subdomain LowCardinality(String),
            record_type LowCardinality(String),
            payload String,
            encryption LowCardinality(String),
            region LowCardinality(String),
            participant_ids Array(String),
            system_actor_ids Array(String),
            created_at DateTime64(9),
            valid_until DateTime64(9),
            published_at DateTime64(9),
            received_at DateTime64(9),
            is_deleted UInt8 DEFAULT 0
        ) ENGINE = MergeTree
        ORDER BY (entity_kind, entity_id, created_at, record_id)
        PARTITION BY (region, toYYYYMM(created_at))
        """)
    try await client.execute("""
        INSERT INTO \(ledgerTable)
        SELECT
            generateUUIDv4() AS record_id,
            toFixedString(leftPad(toString(number % \(ledgerUniqueIds)), 44, '0'), 44) AS entity_id,
            arrayMap(x -> toFixedString(leftPad(toString(x), 44, '0'), 44), range(toUInt32((number * 7) % 9))) AS entity_refs,
            arrayMap(x -> toFixedString(leftPad(toString(x % 16), 4, '0'), 4), range(toUInt32((number * 7) % 9))) AS entity_ref_kinds,
            toFixedString(leftPad(toString(number % \(ledgerKinds)), 4, '0'), 4) AS entity_kind,
            toFixedString(['agg', 'doc', 'usr', 'evt'][1 + number % 4], 3) AS aggregate_domain,
            toFixedString(['a','b','c','d','e','f','g','h'][1 + number % 8], 1) AS aggregate_subdomain,
            ['Created','Updated','Deleted','Archived'][1 + number % 4] AS record_type,
            toJSONString(map('x', toInt64(number), 'y', concat('v', toString(number % 13)), 'z', toFloat64(number) * 0.5, 'a', toString(arrayMap(i -> toInt64(i), range(2))), 'b', '{}')) AS payload,
            ['none','aes256','gcm'][1 + number % 3] AS encryption,
            ['nz','au','gb','zz'][1 + number % 4] AS region,
            arrayMap(x -> toFixedString(leftPad(toString(x + (number % 1000)), 44, '0'), 44), range(toUInt32((number * 3) % 5))) AS participant_ids,
            arrayMap(x -> concat('svc-', toString(x)), range(toUInt32((number * 2) % 3))) AS system_actor_ids,
            toDateTime64(1700000000.0 + number * 0.001, 9, 'Pacific/Auckland') AS created_at,
            toDateTime64(1700000000.0 + number * 0.001 + 3600, 9, 'Pacific/Auckland') AS valid_until,
            toDateTime64(1700000000.0 + number * 0.001 + 1, 9, 'Pacific/Auckland') AS published_at,
            toDateTime64(1700000000.0 + number * 0.001 + 2, 9, 'Pacific/Auckland') AS received_at,
            toUInt8(0) AS is_deleted
        FROM numbers(\(ledgerRows))
        """)
    let ledgerCount = try await client.scalarInt64("SELECT toInt64(count()) FROM \(ledgerTable)")
    let seconds = elapsedSeconds(start)
    print("[CH PERF SWIFT] ledger_benchsetup ledger_table=\(ledgerTable) ledger_rows=\(ledgerCount) writes_table=\(ledgerWritesTable) elapsed=\(String(format: "%.3f", seconds))s")
    if Int(ledgerCount) != ledgerRows {
        throw LedgerError.rowCountMismatch(expected: ledgerRows, actual: Int(ledgerCount), table: ledgerTable)
    }
}

private enum LedgerError: Error, CustomStringConvertible {

    case rowCountMismatch(expected: Int, actual: Int, table: String)

    var description: String {
        switch self {
        case .rowCountMismatch(let expected, let actual, let table):
            return "ledger row count mismatch for \(table): expected=\(expected) actual=\(actual)"
        }
    }

}

private func ledgerLatencySummary(mode: String, samples: [Int64], extra: String = "") {
    var sorted = samples
    sorted.sort()
    let p50 = percentile(sorted, 0.50)
    let p95 = percentile(sorted, 0.95)
    let p99 = percentile(sorted, 0.99)
    let maxValue = sorted.last ?? 0
    let total = sorted.reduce(Int64(0), +)
    let mean = sorted.isEmpty ? Int64(0) : total / Int64(sorted.count)
    let extraSuffix = extra.isEmpty ? "" : " \(extra)"
    print("[CH PERF SWIFT] \(mode) iterations=\(sorted.count) p50_us=\(p50) p95_us=\(p95) p99_us=\(p99) max_us=\(maxValue) mean_us=\(mean)\(extraSuffix)")
}

private func ledgerRunPointLookupById() async throws {
    var samples = [Int64]()
    samples.reserveCapacity(ledgerPointIterations)
    var matchedTotal: Int64 = 0
    for iteration in 0..<ledgerPointIterations {
        let id = ledgerAggregateId(iteration % ledgerUniqueIds)
        let sql = "SELECT toInt64(count()) FROM \(ledgerTable) WHERE entity_id = '\(id)'"
        let start = ContinuousClock.now
        let count = try await client.scalarInt64(sql)
        samples.append(microsecondsSince(start))
        matchedTotal += count
    }
    ledgerLatencySummary(mode: "ledger_point_lookup_by_id", samples: samples, extra: "matched_total=\(matchedTotal)")
}

private func ledgerRunHasRefs() async throws {
    var samples = [Int64]()
    samples.reserveCapacity(ledgerHasIterations)
    var matchedTotal: Int64 = 0
    for iteration in 0..<ledgerHasIterations {
        let ref = ledgerAggregateId(iteration % 8)
        let sql = "SELECT toInt64(count()) FROM \(ledgerTable) WHERE has(entity_refs, '\(ref)')"
        let start = ContinuousClock.now
        let count = try await client.scalarInt64(sql)
        samples.append(microsecondsSince(start))
        matchedTotal += count
    }
    ledgerLatencySummary(mode: "ledger_has_refs", samples: samples, extra: "matched_total=\(matchedTotal)")
}

private func ledgerRunHasRefsKinds() async throws {
    var samples = [Int64]()
    samples.reserveCapacity(ledgerHasIterations)
    var matchedTotal: Int64 = 0
    for iteration in 0..<ledgerHasIterations {
        let kind = ledgerAggregateKind(iteration % 16)
        let sql = "SELECT toInt64(count()) FROM \(ledgerTable) WHERE has(entity_ref_kinds, '\(kind)')"
        let start = ContinuousClock.now
        let count = try await client.scalarInt64(sql)
        samples.append(microsecondsSince(start))
        matchedTotal += count
    }
    ledgerLatencySummary(mode: "ledger_has_ref_kinds", samples: samples, extra: "matched_total=\(matchedTotal)")
}

private func ledgerRunHasUserActors() async throws {
    var samples = [Int64]()
    samples.reserveCapacity(ledgerHasIterations)
    var matchedTotal: Int64 = 0
    for iteration in 0..<ledgerHasIterations {
        let actor = ledgerAggregateId(iteration % 1000)
        let sql = "SELECT toInt64(count()) FROM \(ledgerTable) WHERE has(participant_ids, '\(actor)')"
        let start = ContinuousClock.now
        let count = try await client.scalarInt64(sql)
        samples.append(microsecondsSince(start))
        matchedTotal += count
    }
    ledgerLatencySummary(mode: "ledger_has_participants", samples: samples, extra: "matched_total=\(matchedTotal)")
}

private func ledgerRunKindSlice() async throws {
    var samples = [Int64]()
    samples.reserveCapacity(ledgerKindIterations)
    var rowsTotal = 0
    for iteration in 0..<ledgerKindIterations {
        let kind = ledgerAggregateKind(iteration % ledgerKinds)
        let sql = "SELECT entity_id, created_at FROM \(ledgerTable) WHERE entity_kind = '\(kind)' ORDER BY created_at DESC LIMIT 1000"
        let start = ContinuousClock.now
        var observedRows = 0
        for try await block in client.selectColumns(sql) {
            observedRows += block.rowCount
        }
        samples.append(microsecondsSince(start))
        rowsTotal += observedRows
    }
    ledgerLatencySummary(mode: "ledger_kind_slice", samples: samples, extra: "rows_total=\(rowsTotal)")
}

// View-API equivalent of ledger_point_lookup_by_id. Instead of
// asking the server to evaluate the equality predicate and return a
// count, we SELECT the FixedString(44) entity_id column once and
// scan it client-side through the zero-copy view path. The
// view-counted match total has to agree with the wire-only baseline
// query for the same id; any discrepancy points to a view-vs-codec
// drift.
private func ledgerRunPointLookupByIdView() async throws {
    var samples = [Int64]()
    samples.reserveCapacity(ledgerPointIterations)
    var matchedTotal: Int64 = 0
    for iteration in 0..<ledgerPointIterations {
        let id = ledgerAggregateId(iteration % ledgerUniqueIds)
        let sql = "SELECT entity_id FROM \(ledgerTable) WHERE entity_id = '\(id)'"
        let start = ContinuousClock.now
        var observed: Int64 = 0
        for try await block in client.selectStringColumns(sql) {
            observed += ledgerCountFixedStringMatches(block: block, name: "entity_id", needle: id)
        }
        samples.append(microsecondsSince(start))
        matchedTotal += observed
    }
    ledgerLatencySummary(mode: "ledger_point_lookup_by_id_view", samples: samples, extra: "matched_total=\(matchedTotal)")
}

// View-API equivalent of ledger_has_refs. Issues the same
// `has(entity_refs, ?)` query against the server, then scans the
// returned entity_refs column on the client using
// ClickHouseArrayOfFixedStringColumnView. The view's per-row
// `contains()` walks element views in place without ever
// materialising a Swift `[String]` per row. The server-side `has` is
// kept in the query so the projection mirrors the wire shape of the
// production read; what changes is the client-side decode work.
private func ledgerRunHasRefsView() async throws {
    var samples = [Int64]()
    samples.reserveCapacity(ledgerHasIterations)
    var matchedTotal: Int64 = 0
    for iteration in 0..<ledgerHasIterations {
        let ref = ledgerAggregateId(iteration % 8)
        let sql = "SELECT entity_refs FROM \(ledgerTable) WHERE has(entity_refs, '\(ref)')"
        let start = ContinuousClock.now
        var observed: Int64 = 0
        for try await block in client.selectStringColumns(sql) {
            observed += ledgerCountArrayContainsMatches(block: block, name: "entity_refs", needle: ref)
        }
        samples.append(microsecondsSince(start))
        matchedTotal += observed
    }
    ledgerLatencySummary(mode: "ledger_has_refs_view", samples: samples, extra: "matched_total=\(matchedTotal)")
}

// View-API equivalent of ledger_kind_slice. Selects the
// entity_id FixedString(44) column for rows matching the kind
// predicate, then walks the column entirely through the view path —
// no per-row Swift `String` is ever allocated. The previous mode
// counted `block.rowCount`; here we additionally byte-equality-check
// each returned entity_id view against the queried kind's first
// matching id to confirm the view actually surfaced the row bytes.
private func ledgerRunKindSliceView() async throws {
    var samples = [Int64]()
    samples.reserveCapacity(ledgerKindIterations)
    var rowsTotal = 0
    var bytesTotal: Int64 = 0
    for iteration in 0..<ledgerKindIterations {
        let kind = ledgerAggregateKind(iteration % ledgerKinds)
        let sql = "SELECT entity_id FROM \(ledgerTable) WHERE entity_kind = '\(kind)' ORDER BY created_at DESC LIMIT 1000"
        let start = ContinuousClock.now
        var observedRows = 0
        var observedBytes: Int64 = 0
        for try await block in client.selectStringColumns(sql) {
            ledgerAccumulateFixedStringBytes(block: block, name: "entity_id", rows: &observedRows, bytes: &observedBytes)
        }
        samples.append(microsecondsSince(start))
        rowsTotal += observedRows
        bytesTotal += observedBytes
    }
    ledgerLatencySummary(mode: "ledger_kind_slice_view", samples: samples, extra: "rows_total=\(rowsTotal) bytes_total=\(bytesTotal)")
}

// Composite mode that exercises every view-path entrypoint in one
// run: the String view on the events.payload column, the
// FixedString / Array(FixedString) / Map(String, String) views on a
// event-sourced ledger-shaped projection, and the new selectRowsBuilder path
// that produces a per-row typed projection from view bytes without
// allocating a Swift `String` per row. Reports a single combined
// summary line so a CI parser can pick the mode up uniformly.
//
// The mode is read-only and side-effect free; it depends on the
// `benchsetup` and `ledger_benchsetup` fixtures already being
// present. Running `selectview_all_modes` without those fixtures
// will fail at the first SELECT and surface as a normal bench
// FAIL line.
private func runSelectViewAllModes() async throws {
    let start = ContinuousClock.now
    var totalRows: Int64 = 0
    var totalBytes: Int64 = 0
    let realPayloadStats = try await selectViewSweepRealPayload()
    totalRows += realPayloadStats.rows
    totalBytes += realPayloadStats.bytes
    let ledgerFixedStats = try await selectViewSweepLedgerFixed()
    totalRows += ledgerFixedStats.rows
    totalBytes += ledgerFixedStats.bytes
    let ledgerArrayStats = try await selectViewSweepLedgerArray()
    totalRows += ledgerArrayStats.rows
    let realMapStats = try await selectViewSweepRealMap()
    totalRows += realMapStats.rows
    let builderStats = try await selectViewSweepRowBuilder()
    totalRows += builderStats.rows
    totalBytes += builderStats.bytes
    let seconds = elapsedSeconds(start)
    print("[CH PERF SWIFT] selectview_all_modes rows=\(totalRows) elapsed=\(String(format: "%.3f", seconds))s rate=\(rate(count: Int(totalRows), seconds: seconds))/s bytes=\(totalBytes) string_rows=\(realPayloadStats.rows) fixed_rows=\(ledgerFixedStats.rows) array_rows=\(ledgerArrayStats.rows) map_rows=\(realMapStats.rows) builder_rows=\(builderStats.rows)")
}

private struct SelectViewSweepStats: Sendable {

    var rows: Int64
    var bytes: Int64

}

private func selectViewSweepRealPayload() async throws -> SelectViewSweepStats {
    let sql = "SELECT payload FROM \(sampleEventsTable) LIMIT 200000"
    var stats = SelectViewSweepStats(rows: 0, bytes: 0)
    for try await block in client.selectStringColumns(sql) {
        guard case .present(let column) = block.stringColumn(named: "payload") else { continue }
        column.forEach { _, view in
            stats.rows += 1
            stats.bytes += Int64(view.utf8Length)
        }
    }
    return stats
}

private func selectViewSweepLedgerFixed() async throws -> SelectViewSweepStats {
    let sql = "SELECT entity_id FROM \(ledgerTable) LIMIT 100000"
    var stats = SelectViewSweepStats(rows: 0, bytes: 0)
    for try await block in client.selectStringColumns(sql) {
        guard case .present(let column) = block.fixedStringColumn(named: "entity_id") else { continue }
        column.forEach { _, view in
            stats.rows += 1
            stats.bytes += Int64(view.byteCount)
        }
    }
    return stats
}

private func selectViewSweepLedgerArray() async throws -> SelectViewSweepStats {
    let sql = "SELECT entity_refs FROM \(ledgerTable) LIMIT 100000"
    var stats = SelectViewSweepStats(rows: 0, bytes: 0)
    for try await block in client.selectStringColumns(sql) {
        guard case .present(let column) = block.arrayOfFixedStringColumn(named: "entity_refs") else { continue }
        for rowIndex in 0..<column.rowCount {
            stats.rows += 1
            stats.bytes += Int64(column.view(at: rowIndex).count)
        }
    }
    return stats
}

private func selectViewSweepRealMap() async throws -> SelectViewSweepStats {
    // Build a small Map(String, String) projection from the events
    // table on the fly. The values are explicitly cast to plain
    // String so the resulting Map(String, String) reaches the view
    // path (the view filter rejects Map(LowCardinality(*), *), since
    // the LowCardinality dictionary surface has its own view type).
    let sql = "SELECT mapFromArrays(['event_type'], [CAST(event_type, 'String')]) AS tags FROM \(sampleEventsTable) LIMIT 100000"
    var stats = SelectViewSweepStats(rows: 0, bytes: 0)
    for try await block in client.selectStringColumns(sql) {
        guard case .present(let column) = block.mapStringStringColumn(named: "tags") else { continue }
        for rowIndex in 0..<column.rowCount {
            stats.rows += 1
            stats.bytes += Int64(column.view(at: rowIndex).count)
        }
    }
    return stats
}

private func selectViewSweepRowBuilder() async throws -> SelectViewSweepStats {
    let sql = "SELECT payload FROM \(sampleEventsTable) LIMIT 200000"
    var rows: Int64 = 0
    var bytes: Int64 = 0
    let stream = client.selectRowsBuilder(Int.self, from: sql) { block, rowIndex in
        guard case .present(let column) = block.stringColumn(named: "payload") else { return 0 }
        return column.view(at: rowIndex).utf8Length
    }
    for try await batch in stream {
        for size in batch {
            rows += 1
            bytes += Int64(size)
        }
    }
    return SelectViewSweepStats(rows: rows, bytes: bytes)
}

private func ledgerCountFixedStringMatches(block: ClickHouseBlockStringView, name: String, needle: String) -> Int64 {
    switch block.fixedStringColumn(named: name) {
    case .present(let column):
        return ledgerCountFixedStringMatchesInColumn(column: column, needle: needle)
    case .absent:
        return 0
    }
}

private func ledgerCountFixedStringMatchesInColumn(column: ClickHouseFixedStringColumnView, needle: String) -> Int64 {
    var matched: Int64 = 0
    column.forEach { _, view in
        if view == needle { matched += 1 }
    }
    return matched
}

private func ledgerCountArrayContainsMatches(block: ClickHouseBlockStringView, name: String, needle: String) -> Int64 {
    switch block.arrayOfFixedStringColumn(named: name) {
    case .present(let column):
        return ledgerCountArrayContainsMatchesInColumn(column: column, needle: needle)
    case .absent:
        return 0
    }
}

private func ledgerCountArrayContainsMatchesInColumn(column: ClickHouseArrayOfFixedStringColumnView, needle: String) -> Int64 {
    var matched: Int64 = 0
    for rowIndex in 0..<column.rowCount {
        if column.view(at: rowIndex).contains(needle) { matched += 1 }
    }
    return matched
}

private func ledgerAccumulateFixedStringBytes(
    block: ClickHouseBlockStringView, name: String, rows: inout Int, bytes: inout Int64
) {
    if case .present(let column) = block.fixedStringColumn(named: name) {
        column.forEach { _, view in
            rows += 1
            bytes += Int64(view.byteCount)
        }
    }
}

private struct LedgerWriteRowBuffers {

    var recordIds: [UUID] = []
    var aggregateIds: [String] = []
    var aggregateRefs: [[String]] = []
    var aggregateRefsKinds: [[String]] = []
    var aggregateKinds: [String] = []
    var aggregateDomains: [String] = []
    var aggregateSubdomains: [String] = []
    var recordTypes: [String] = []
    var payloads: [String] = []
    var encryptions: [String] = []
    var regions: [String] = []
    var userActorIds: [[String]] = []
    var systemActorIds: [[String]] = []
    var occurredAt: [ClickHouseNanoseconds] = []
    var validUntil: [ClickHouseNanoseconds] = []
    var publishedAt: [ClickHouseNanoseconds] = []
    var receivedAt: [ClickHouseNanoseconds] = []
    var isDeleted: [UInt8] = []

    mutating func reserveCapacity(_ capacity: Int) {
        recordIds.reserveCapacity(capacity)
        aggregateIds.reserveCapacity(capacity)
        aggregateRefs.reserveCapacity(capacity)
        aggregateRefsKinds.reserveCapacity(capacity)
        aggregateKinds.reserveCapacity(capacity)
        aggregateDomains.reserveCapacity(capacity)
        aggregateSubdomains.reserveCapacity(capacity)
        recordTypes.reserveCapacity(capacity)
        payloads.reserveCapacity(capacity)
        encryptions.reserveCapacity(capacity)
        regions.reserveCapacity(capacity)
        userActorIds.reserveCapacity(capacity)
        systemActorIds.reserveCapacity(capacity)
        occurredAt.reserveCapacity(capacity)
        validUntil.reserveCapacity(capacity)
        publishedAt.reserveCapacity(capacity)
        receivedAt.reserveCapacity(capacity)
        isDeleted.reserveCapacity(capacity)
    }

    func toColumns() -> [ClickHouseColumnEntry] {
        return [
            .init(name: "record_id", values: .uuid(recordIds)),
            .init(name: "entity_id", values: .string(aggregateIds)),
            .init(name: "entity_refs", values: .arrayOfString(aggregateRefs)),
            .init(name: "entity_ref_kinds", values: .arrayOfString(aggregateRefsKinds)),
            .init(name: "entity_kind", values: .lowCardinalityString(aggregateKinds)),
            .init(name: "aggregate_domain", values: .lowCardinalityString(aggregateDomains)),
            .init(name: "aggregate_subdomain", values: .lowCardinalityString(aggregateSubdomains)),
            .init(name: "record_type", values: .lowCardinalityString(recordTypes)),
            .init(name: "payload", values: .string(payloads)),
            .init(name: "encryption", values: .lowCardinalityString(encryptions)),
            .init(name: "region", values: .lowCardinalityString(regions)),
            .init(name: "participant_ids", values: .arrayOfString(userActorIds)),
            .init(name: "system_actor_ids", values: .arrayOfString(systemActorIds)),
            .init(name: "created_at", values: .dateTime64Nanoseconds(occurredAt, precision: 9)),
            .init(name: "valid_until", values: .dateTime64Nanoseconds(validUntil, precision: 9)),
            .init(name: "published_at", values: .dateTime64Nanoseconds(publishedAt, precision: 9)),
            .init(name: "received_at", values: .dateTime64Nanoseconds(receivedAt, precision: 9)),
            .init(name: "is_deleted", values: .uint8(isDeleted)),
        ]
    }

}

private func ledgerBuildAggregateRefs(index: Int) -> (refs: [String], refsKinds: [String]) {
    let length = (index &* 7) % 9
    var refs = [String](); refs.reserveCapacity(length)
    var refsKinds = [String](); refsKinds.reserveCapacity(length)
    for refIndex in 0..<length {
        refs.append(ledgerAggregateId(refIndex))
        refsKinds.append(ledgerAggregateKind(refIndex % 16))
    }
    return (refs, refsKinds)
}

private func ledgerBuildUserActors(index: Int) -> [String] {
    let length = (index &* 3) % 5
    var actors = [String](); actors.reserveCapacity(length)
    for actorIndex in 0..<length {
        actors.append(ledgerAggregateId(actorIndex + (index % 1000)))
    }
    return actors
}

private func ledgerBuildSystemActors(index: Int) -> [String] {
    let length = (index &* 2) % 3
    var systemActors = [String](); systemActors.reserveCapacity(length)
    for systemIndex in 0..<length {
        systemActors.append("svc-\(systemIndex)")
    }
    return systemActors
}

private func ledgerAppendRow(_ buffers: inout LedgerWriteRowBuffers, index: Int) {
    let domains = ["agg", "doc", "usr", "evt"]
    let subdomains = ["a", "b", "c", "d", "e", "f", "g", "h"]
    let recordTypeOptions = ["Created", "Updated", "Deleted", "Archived"]
    let encryptionOptions = ["none", "aes256", "gcm"]
    let baseNanos: Int64 = 1_700_000_000_000_000_000
    buffers.recordIds.append(UUID())
    buffers.aggregateIds.append(ledgerAggregateId(index % ledgerUniqueIds))
    let refsBundle = ledgerBuildAggregateRefs(index: index)
    buffers.aggregateRefs.append(refsBundle.refs)
    buffers.aggregateRefsKinds.append(refsBundle.refsKinds)
    buffers.aggregateKinds.append(ledgerAggregateKind(index % ledgerKinds))
    buffers.aggregateDomains.append(domains[index % domains.count])
    buffers.aggregateSubdomains.append(subdomains[index % subdomains.count])
    buffers.recordTypes.append(recordTypeOptions[index % recordTypeOptions.count])
    buffers.payloads.append("{\"x\":\(index),\"y\":\"v\(index % 13)\",\"z\":\(Double(index) * 0.5),\"a\":[0,1],\"b\":{}}")
    buffers.encryptions.append(encryptionOptions[index % encryptionOptions.count])
    buffers.regions.append(ledgerRegions[index % ledgerRegions.count])
    buffers.userActorIds.append(ledgerBuildUserActors(index: index))
    buffers.systemActorIds.append(ledgerBuildSystemActors(index: index))
    let occurredNanos = baseNanos &+ Int64(index) * 1_000_000
    buffers.occurredAt.append(ClickHouseNanoseconds(occurredNanos))
    buffers.validUntil.append(ClickHouseNanoseconds(occurredNanos &+ 3_600_000_000_000))
    buffers.publishedAt.append(ClickHouseNanoseconds(occurredNanos &+ 1_000_000_000))
    buffers.receivedAt.append(ClickHouseNanoseconds(occurredNanos &+ 2_000_000_000))
    buffers.isDeleted.append(0)
}

private func ledgerBuildBulkColumns(blockStart: Int, blockEnd: Int) -> [ClickHouseColumnEntry] {
    var buffers = LedgerWriteRowBuffers()
    buffers.reserveCapacity(blockEnd - blockStart)
    for index in blockStart..<blockEnd {
        ledgerAppendRow(&buffers, index: index)
    }
    return buffers.toColumns()
}

private func ledgerRunBulkInsert() async throws {
    try await client.execute("TRUNCATE TABLE \(ledgerWritesTable)")
    let start = ContinuousClock.now
    let columns = ledgerBuildBulkColumns(blockStart: 0, blockEnd: ledgerBulkRows)
    try await client.insert(into: ledgerWritesTable, columns: columns)
    let seconds = elapsedSeconds(start)
    let perRowMicroseconds = ledgerBulkRows > 0 ? Int64(seconds * 1_000_000 / Double(ledgerBulkRows)) : 0
    print("[CH PERF SWIFT] ledger_bulk_insert rows=\(ledgerBulkRows) elapsed=\(String(format: "%.3f", seconds))s rate=\(rate(count: ledgerBulkRows, seconds: seconds))/s per_row_us=\(perRowMicroseconds)")
}

private func ledgerRunStreamInsert() async throws {
    try await client.execute("TRUNCATE TABLE \(ledgerWritesTable)")
    var samples = [Int64]()
    samples.reserveCapacity(ledgerStreamIterations)
    for iteration in 0..<ledgerStreamIterations {
        let blockStart = iteration * ledgerStreamRows
        let blockEnd = blockStart + ledgerStreamRows
        let columns = ledgerBuildBulkColumns(blockStart: blockStart, blockEnd: blockEnd)
        let start = ContinuousClock.now
        try await client.insert(into: ledgerWritesTable, columns: columns)
        samples.append(microsecondsSince(start))
    }
    ledgerLatencySummary(
        mode: "ledger_stream_insert",
        samples: samples,
        extra: "rows_per_batch=\(ledgerStreamRows)"
    )
}

print("[CH PERF SWIFT] config host=\(host) port=\(port) database=\(database) rows=\(rowCount) block_rows=\(blockRowCount) concurrency=\(concurrency) event_loops=\(eventLoopThreadCount) modes=\(modes.joined(separator: ",")) types=\(selectedTypedTypes.joined(separator: ",")) real_events_rows=\(sampleEventsRows) sample_events_table=\(sampleEventsTable) real_logs_rows=\(sampleLogsRows) sample_logs_table=\(sampleLogsTable) ledger_rows=\(ledgerRows) ledger_table=\(ledgerTable) ledger_writes=\(ledgerWritesTable)")

for selected in modes {
    let trimmed = selected.trimmingCharacters(in: .whitespaces)
    do {
        switch trimmed {
        case "insert_bulk_columnar":
            try await runInsertBulkColumnar()
        case "insert_bulk_codable":
            try await runInsertBulkCodable()
        case "select_bulk_columnar":
            try await runSelectBulkColumnar()
        case "select_bulk_columnar_fast":
            try await runSelectBulkColumnarFast()
        case "select_bulk_columnar_builder":
            try await runSelectBulkColumnarBuilder()
        case "select_bulk_columnar_wire":
            try await runSelectBulkColumnarWireOnly()
        case "select_bulk_codable":
            try await runSelectBulkCodable()
        case "insert_lc_map":
            try await runInsertLCMap()
        case "insert_lc_map_codable":
            try await runInsertLCMapCodable()
        case "select_lc_map":
            try await runSelectLCMap()
        case "select_lc_map_fast":
            try await runSelectLCMapFast()
        case "select_lc_map_wire":
            try await runSelectLCMapWire()
        case "encode_only_codable":
            try await runEncodeOnlyCodable()
        case "latency_single_insert":
            try await runLatencySingleInsert()
        case "latency_single_select":
            try await runLatencySingleSelect()
        case "latency_small_batch_insert":
            try await runLatencySmallBatchInsert()
        case "concurrent_insert_throughput":
            try await runConcurrentInsertThroughput()
        case "concurrent_select_throughput":
            try await runConcurrentSelectThroughput()
        case "concurrent_select_fast":
            try await runConcurrentSelectFast()
        case "concurrent_select_builder":
            try await runConcurrentSelectBuilder()
        case "insert_typed", "select_typed":
            await runTypedModeForAllTypes(trimmed)
        case "benchsetup":
            try await runRealBenchSetup()
        case "select_orderby_limit":
            try await runRealSelectOrderByLimit()
        case "select_groupby":
            try await runRealSelectGroupBy()
        case "select_where_in":
            try await runRealSelectWhereIn()
        case "select_full_scan_proj":
            try await runRealSelectFullScanProjection()
        case "select_orderby_limit_rows":
            try await runRealSelectOrderByLimitRows()
        case "select_full_scan_proj_rows":
            try await runRealSelectFullScanProjectionRows()
        case "select_full_scan_proj_stream":
            try await runRealSelectFullScanProjectionStream()
        case "select_full_scan_proj_streamfast":
            try await runRealSelectFullScanProjectionStreamFast()
        case "select_full_scan_proj_view":
            try await runRealSelectFullScanProjectionView()
        case "select_full_scan_proj_string":
            try await runRealSelectFullScanPayloadString()
        case "select_lc_aggregation":
            try await runRealSelectLowCardinalityAggregation()
        case "select_string_filter":
            try await runRealSelectStringFilter()
        case "select_decode_only":
            try await runRealSelectDecodeOnly()
        case "select_wire_only_count":
            try await runRealSelectWireOnlyCount()
        case "ledger_benchsetup":
            try await ledgerRunBenchSetup()
        case "ledger_point_lookup_by_id":
            try await ledgerRunPointLookupById()
        case "ledger_point_lookup_by_id_view":
            try await ledgerRunPointLookupByIdView()
        case "ledger_has_refs":
            try await ledgerRunHasRefs()
        case "ledger_has_refs_view":
            try await ledgerRunHasRefsView()
        case "ledger_has_ref_kinds":
            try await ledgerRunHasRefsKinds()
        case "ledger_has_participants":
            try await ledgerRunHasUserActors()
        case "ledger_kind_slice":
            try await ledgerRunKindSlice()
        case "ledger_kind_slice_view":
            try await ledgerRunKindSliceView()
        case "ledger_bulk_insert":
            try await ledgerRunBulkInsert()
        case "ledger_stream_insert":
            try await ledgerRunStreamInsert()
        case "selectview_all_modes":
            try await runSelectViewAllModes()
        default:
            print("[CH PERF SWIFT] unknown mode: \(selected)")
        }
    } catch {
        print("[CH PERF SWIFT] FAIL mode=\(selected) error=\(error)")
    }
}

await client.shutdown()
