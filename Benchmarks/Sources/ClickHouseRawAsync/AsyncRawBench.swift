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

import DXClickHouseRaw
import Foundation

// Async-wrapped raw-transport benchmark. Mirrors the SQL surface and
// mode list of ClickHouseRawBenchmark but drives every query through
// `AsyncRawClickHouseConnection`. The point is to measure the per-mode
// cost of the async/await + DispatchQueue + CheckedContinuation
// wrapper relative to the synchronous RawClickHouseConnection floor.
//
// Output is namespaced `[CH PERF RAW-ASYNC]` so a CI parser can compare
// it directly against `[CH PERF RAW]` (sync raw) and `[CH PERF CPP]`
// (clickhouse-cpp).

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

private let sampleEventsRows = envInt("CH_BENCH_EVENTS_ROWS", 10_000_000)
private let sampleLogsRows = envInt("CH_BENCH_LOGS_ROWS", 1_000_000)
private let sampleFixtureDatabase = envString("CH_BENCH_SAMPLE_DATABASE", "bench_sample")
private let sampleEventsTable = "\(sampleFixtureDatabase).events_\(sampleEventsRows / 1_000_000)M"
private let sampleLogsTable = "\(sampleFixtureDatabase).logs_\(sampleLogsRows / 1_000_000)M"
private let sampleDecodeOnlyIterations = max(1, envInt("CH_BENCH_SAMPLE_DECODE_ITERATIONS", 5))

private let ledgerRows = envInt("CH_BENCH_LEDGER_ROWS", 10_000_000)
private let ledgerUniqueIds = max(1, envInt("CH_BENCH_LEDGER_UNIQUE_IDS", 100_000))
private let ledgerKinds = max(1, envInt("CH_BENCH_LEDGER_KINDS", 2_000))
private let ledgerPointIterations = max(1, envInt("CH_BENCH_LEDGER_POINT_ITERATIONS", 1_000))
private let ledgerHasIterations = max(1, envInt("CH_BENCH_LEDGER_HAS_ITERATIONS", 1_000))
private let ledgerKindIterations = max(1, envInt("CH_BENCH_LEDGER_KIND_ITERATIONS", 100))
private let ledgerDatabase = envString("CH_BENCH_LEDGER_DATABASE", "bench_ledgers")
private let ledgerTable = "\(ledgerDatabase).ledger_\(ledgerRows / 1_000_000)M"

private let modes = envString(
    "CH_BENCH_MODES",
    "select_orderby_limit,select_groupby,select_where_in,select_full_scan_proj,select_lc_aggregation,select_string_filter,select_decode_only,select_wire_only_count,select_full_scan_proj_view,ledger_point_lookup_by_id,ledger_has_refs,ledger_has_ref_kinds,ledger_has_participants,ledger_kind_slice,ledger_bulk_insert,ledger_stream_insert"
).split(separator: ",").map(String.init)

private func elapsedSeconds(_ start: ContinuousClock.Instant) -> Double {
    let nanos = ContinuousClock.now - start
    return Double(nanos.components.attoseconds) / 1e18 + Double(nanos.components.seconds)
}

private func microsecondsSince(_ start: ContinuousClock.Instant) -> Int64 {
    let nanos = ContinuousClock.now - start
    let seconds = Double(nanos.components.seconds)
    let attos = Double(nanos.components.attoseconds) / 1e18
    return Int64((seconds + attos) * 1_000_000)
}

private func rate(count: Int, seconds: Double) -> Int {
    seconds > 0 ? Int(Double(count) / seconds) : 0
}

private func summary(mode: String, rows: Int, seconds: Double, firstByteMicroseconds: Int64, totalDecodeMicroseconds: Int64, extra: String = "") {
    let extraSuffix = extra.isEmpty ? "" : " \(extra)"
    print("[CH PERF RAW-ASYNC] \(mode) rows=\(rows) elapsed=\(String(format: "%.3f", seconds))s rate=\(rate(count: rows, seconds: seconds))/s first_byte_us=\(firstByteMicroseconds) total_decode_us=\(totalDecodeMicroseconds)\(extraSuffix)")
}

private func latencySummary(mode: String, samples: [Int64], extra: String = "") {
    var sorted = samples
    sorted.sort()
    let p50 = percentile(sorted, 0.50)
    let p95 = percentile(sorted, 0.95)
    let p99 = percentile(sorted, 0.99)
    let maxValue = sorted.last ?? 0
    let total = sorted.reduce(Int64(0), +)
    let mean = sorted.isEmpty ? Int64(0) : total / Int64(sorted.count)
    let extraSuffix = extra.isEmpty ? "" : " \(extra)"
    print("[CH PERF RAW-ASYNC] \(mode) iterations=\(sorted.count) p50_us=\(p50) p95_us=\(p95) p99_us=\(p99) max_us=\(maxValue) mean_us=\(mean)\(extraSuffix)")
}

private func percentile(_ sortedSamples: [Int64], _ fraction: Double) -> Int64 {
    guard !sortedSamples.isEmpty else { return 0 }
    let position = max(0, min(sortedSamples.count - 1, Int((Double(sortedSamples.count) * fraction).rounded(.down))))
    return sortedSamples[position]
}

private struct AsyncBenchmarkRunner {

    let connection: AsyncRawClickHouseConnection

    // Drain wrapper: send + drainBlocks() in a single round-trip. The
    // drainBlocks() path is the cheapest async surface (one continuation
    // hop per query) so this mirrors the sync `drainQuery` shape with
    // minimum async overhead.
    func drainQuery(_ sql: String) async throws -> (rows: Int, totalSeconds: Double, firstByteMicroseconds: Int64) {
        let totalStart = ContinuousClock.now
        try await connection.sendQuery(sql)
        let firstByteMicroseconds = microsecondsSince(totalStart)
        let rows = try await connection.drainBlocks()
        return (rows, elapsedSeconds(totalStart), firstByteMicroseconds)
    }

    func scalarUInt64(_ sql: String) async throws -> UInt64 {
        try await connection.sendQuery(sql)
        return try await connection.receiveScalarUInt64()
    }

    func runRealSelectOrderByLimit() async throws {
        let sql = "SELECT id, user_id, event_type, value, payload, ts FROM \(sampleEventsTable) WHERE event_type = 'click' ORDER BY ts DESC LIMIT 100000"
        let result = try await drainQuery(sql)
        summary(mode: "select_orderby_limit", rows: result.rows, seconds: result.totalSeconds, firstByteMicroseconds: result.firstByteMicroseconds, totalDecodeMicroseconds: 0)
    }

    func runRealSelectGroupBy() async throws {
        let sql = "SELECT user_id, count(*) AS c FROM \(sampleEventsTable) GROUP BY user_id ORDER BY c DESC LIMIT 10000"
        let result = try await drainQuery(sql)
        summary(mode: "select_groupby", rows: result.rows, seconds: result.totalSeconds, firstByteMicroseconds: result.firstByteMicroseconds, totalDecodeMicroseconds: 0)
    }

    func runRealSelectWhereIn() async throws {
        let sql = "SELECT id, user_id, ts, value FROM \(sampleEventsTable) WHERE user_id IN (SELECT number FROM numbers(1, 100000))"
        let result = try await drainQuery(sql)
        summary(mode: "select_where_in", rows: result.rows, seconds: result.totalSeconds, firstByteMicroseconds: result.firstByteMicroseconds, totalDecodeMicroseconds: 0)
    }

    func runRealSelectFullScanProjection() async throws {
        let sql = "SELECT id, ts, value FROM \(sampleEventsTable)"
        let result = try await drainQuery(sql)
        summary(mode: "select_full_scan_proj", rows: result.rows, seconds: result.totalSeconds, firstByteMicroseconds: result.firstByteMicroseconds, totalDecodeMicroseconds: 0)
    }

    func runRealSelectLowCardinalityAggregation() async throws {
        let sql = "SELECT event_type, avg(value) AS avg_value FROM \(sampleEventsTable) GROUP BY event_type"
        let result = try await drainQuery(sql)
        summary(mode: "select_lc_aggregation", rows: result.rows, seconds: result.totalSeconds, firstByteMicroseconds: result.firstByteMicroseconds, totalDecodeMicroseconds: 0)
    }

    func runRealSelectStringFilter() async throws {
        let sql = "SELECT count(*) AS matched FROM \(sampleEventsTable) WHERE payload LIKE '%abc%'"
        let totalStart = ContinuousClock.now
        let matched = try await scalarUInt64(sql)
        summary(mode: "select_string_filter", rows: 1, seconds: elapsedSeconds(totalStart), firstByteMicroseconds: 0, totalDecodeMicroseconds: 0, extra: "matched=\(matched)")
    }

    func runRealSelectDecodeOnly() async throws {
        let sql = "SELECT id, ts, value FROM \(sampleEventsTable)"
        _ = try await drainQuery(sql)
        var samplesMicroseconds = [Int64]()
        samplesMicroseconds.reserveCapacity(sampleDecodeOnlyIterations)
        var lastRows = 0
        var lastFirstByte: Int64 = 0
        for _ in 0..<sampleDecodeOnlyIterations {
            let result = try await drainQuery(sql)
            samplesMicroseconds.append(Int64(result.totalSeconds * 1_000_000))
            lastRows = result.rows
            lastFirstByte = result.firstByteMicroseconds
        }
        samplesMicroseconds.sort()
        let medianSeconds = Double(samplesMicroseconds[samplesMicroseconds.count / 2]) / 1_000_000
        summary(
            mode: "select_decode_only",
            rows: lastRows,
            seconds: medianSeconds,
            firstByteMicroseconds: lastFirstByte,
            totalDecodeMicroseconds: 0,
            extra: "iterations=\(sampleDecodeOnlyIterations)"
        )
    }

    func runRealSelectWireOnlyCount() async throws {
        let sql = "SELECT id, user_id, event_type, value, payload, ts FROM \(sampleEventsTable)"
        let result = try await drainQuery(sql)
        summary(mode: "select_wire_only_count", rows: result.rows, seconds: result.totalSeconds, firstByteMicroseconds: result.firstByteMicroseconds, totalDecodeMicroseconds: 0)
    }

    func runRealSelectFullScanProjectionView() async throws {
        let sql = "SELECT payload FROM \(sampleEventsTable)"
        let totalStart = ContinuousClock.now
        try await connection.sendQuery(sql)
        let firstByteMicroseconds = microsecondsSince(totalStart)
        let (rows, totalBytes) = try await connection.extractStringsDrain()
        summary(
            mode: "select_full_scan_proj_view",
            rows: rows,
            seconds: elapsedSeconds(totalStart),
            firstByteMicroseconds: firstByteMicroseconds,
            totalDecodeMicroseconds: 0,
            extra: "bytes=\(totalBytes) observed=\(rows)"
        )
    }

    func ledgerRunPointLookupById() async throws {
        var samples = [Int64]()
        samples.reserveCapacity(ledgerPointIterations)
        var matchedTotal: Int64 = 0
        for iteration in 0..<ledgerPointIterations {
            let id = ledgerAggregateId(iteration % ledgerUniqueIds)
            let sql = "SELECT toInt64(count()) FROM \(ledgerTable) WHERE entity_id = '\(id)'"
            let start = ContinuousClock.now
            let count = try await scalarUInt64(sql)
            samples.append(microsecondsSince(start))
            matchedTotal += Int64(bitPattern: count)
        }
        latencySummary(mode: "ledger_point_lookup_by_id", samples: samples, extra: "matched_total=\(matchedTotal)")
    }

    func ledgerRunHasRefs() async throws {
        var samples = [Int64]()
        samples.reserveCapacity(ledgerHasIterations)
        var matchedTotal: Int64 = 0
        for iteration in 0..<ledgerHasIterations {
            let ref = ledgerAggregateId(iteration % 8)
            let sql = "SELECT toInt64(count()) FROM \(ledgerTable) WHERE has(entity_refs, '\(ref)')"
            let start = ContinuousClock.now
            let count = try await scalarUInt64(sql)
            samples.append(microsecondsSince(start))
            matchedTotal += Int64(bitPattern: count)
        }
        latencySummary(mode: "ledger_has_refs", samples: samples, extra: "matched_total=\(matchedTotal)")
    }

    func ledgerRunHasRefsKinds() async throws {
        var samples = [Int64]()
        samples.reserveCapacity(ledgerHasIterations)
        var matchedTotal: Int64 = 0
        for iteration in 0..<ledgerHasIterations {
            let kind = ledgerAggregateKind(iteration % 16)
            let sql = "SELECT toInt64(count()) FROM \(ledgerTable) WHERE has(entity_ref_kinds, '\(kind)')"
            let start = ContinuousClock.now
            let count = try await scalarUInt64(sql)
            samples.append(microsecondsSince(start))
            matchedTotal += Int64(bitPattern: count)
        }
        latencySummary(mode: "ledger_has_ref_kinds", samples: samples, extra: "matched_total=\(matchedTotal)")
    }

    func ledgerRunHasUserActors() async throws {
        var samples = [Int64]()
        samples.reserveCapacity(ledgerHasIterations)
        var matchedTotal: Int64 = 0
        for iteration in 0..<ledgerHasIterations {
            let actor = ledgerAggregateId(iteration % 1000)
            let sql = "SELECT toInt64(count()) FROM \(ledgerTable) WHERE has(participant_ids, '\(actor)')"
            let start = ContinuousClock.now
            let count = try await scalarUInt64(sql)
            samples.append(microsecondsSince(start))
            matchedTotal += Int64(bitPattern: count)
        }
        latencySummary(mode: "ledger_has_participants", samples: samples, extra: "matched_total=\(matchedTotal)")
    }

    func ledgerRunKindSlice() async throws {
        var samples = [Int64]()
        samples.reserveCapacity(ledgerKindIterations)
        var rowsTotal = 0
        for iteration in 0..<ledgerKindIterations {
            let kind = ledgerAggregateKind(iteration % ledgerKinds)
            let sql = "SELECT entity_id, created_at FROM \(ledgerTable) WHERE entity_kind = '\(kind)' ORDER BY created_at DESC LIMIT 1000"
            let start = ContinuousClock.now
            let result = try await drainQuery(sql)
            samples.append(microsecondsSince(start))
            rowsTotal += result.rows
        }
        latencySummary(mode: "ledger_kind_slice", samples: samples, extra: "rows_total=\(rowsTotal)")
    }
}

private func ledgerZeroPadded(value: Int, width: Int) -> String {
    var digits: [UInt8] = []
    digits.reserveCapacity(20)
    var remaining = value < 0 ? -value : value
    if remaining == 0 {
        digits.append(0x30)
    } else {
        while remaining > 0 {
            digits.append(UInt8(0x30 &+ (remaining % 10)))
            remaining /= 10
        }
    }
    digits.reverse()
    if digits.count >= width {
        return String(unsafeUninitializedCapacity: width) { buffer in
            for index in 0..<width {
                buffer[index] = digits[index]
            }
            return width
        }
    }
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

private func ledgerAggregateId(_ index: Int) -> String {
    ledgerZeroPadded(value: index, width: 44)
}

private func ledgerAggregateKind(_ index: Int) -> String {
    ledgerZeroPadded(value: index, width: 4)
}

private func reportInsertSkip(_ mode: String) {
    print("[CH PERF RAW-ASYNC] SKIP \(mode) reason=client-side INSERT encoding not yet implemented in raw transport")
}

@main
struct AsyncRawBench {

    static func main() async {
        let connection: AsyncRawClickHouseConnection
        do {
            connection = try await AsyncRawClickHouseConnection(host: host, port: port, user: user, password: password, database: database)
        } catch {
            print("[CH PERF RAW-ASYNC] FATAL connect host=\(host) port=\(port) error=\(error)")
            exit(1)
        }

        let runner = AsyncBenchmarkRunner(connection: connection)

        print("[CH PERF RAW-ASYNC] config host=\(host) port=\(port) database=\(database) server=\(connection.serverInfo.name) revision=\(connection.serverInfo.revision) modes=\(modes.joined(separator: ",")) sample_events_table=\(sampleEventsTable) sample_logs_table=\(sampleLogsTable) ledger_table=\(ledgerTable)")

        for selected in modes {
            let trimmed = selected.trimmingCharacters(in: .whitespaces)
            do {
                switch trimmed {
                case "select_orderby_limit":
                    try await runner.runRealSelectOrderByLimit()
                case "select_groupby":
                    try await runner.runRealSelectGroupBy()
                case "select_where_in":
                    try await runner.runRealSelectWhereIn()
                case "select_full_scan_proj":
                    try await runner.runRealSelectFullScanProjection()
                case "select_lc_aggregation":
                    try await runner.runRealSelectLowCardinalityAggregation()
                case "select_string_filter":
                    try await runner.runRealSelectStringFilter()
                case "select_decode_only":
                    try await runner.runRealSelectDecodeOnly()
                case "select_wire_only_count":
                    try await runner.runRealSelectWireOnlyCount()
                case "select_full_scan_proj_view":
                    try await runner.runRealSelectFullScanProjectionView()
                case "ledger_point_lookup_by_id":
                    try await runner.ledgerRunPointLookupById()
                case "ledger_has_refs":
                    try await runner.ledgerRunHasRefs()
                case "ledger_has_ref_kinds":
                    try await runner.ledgerRunHasRefsKinds()
                case "ledger_has_participants":
                    try await runner.ledgerRunHasUserActors()
                case "ledger_kind_slice":
                    try await runner.ledgerRunKindSlice()
                case "ledger_bulk_insert":
                    reportInsertSkip("ledger_bulk_insert")
                case "ledger_stream_insert":
                    reportInsertSkip("ledger_stream_insert")
                default:
                    print("[CH PERF RAW-ASYNC] unknown mode: \(selected)")
                }
            } catch {
                print("[CH PERF RAW-ASYNC] FAIL mode=\(selected) error=\(error)")
            }
        }

        await connection.close()
    }
}
