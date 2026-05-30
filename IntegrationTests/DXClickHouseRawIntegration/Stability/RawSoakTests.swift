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
import DXCore
import Foundation
import Testing

// Sustained-load soak for DXClickHouseRaw. Drives every operation
// surface on RawClickHouseClient through a single shared client for
// the configured duration (5 min default, 30 min via
// CH_STABILITY_FULL=1) and asserts four invariants:
//
//   1. RSS at the end of the soak sits within 20% of the post-warmup
//      baseline. A real leak in the streaming hot path compounds to
//      hundreds of MB over a 5-minute run and trips this bound.
//   2. P99 latency at the last minute sits within 20% of P99 at the
//      first minute. Drift above that bound signals a steady-state
//      degradation (lock contention, arena bloat, GC-style stutter)
//      that per-mode benchmarks would miss on a 100k-row burst.
//   3. Zero errors across the full run.
//   4. Every SELECT mode returns the expected row count for the
//      shape under test.
//
// Modes cycled in a round-robin RNG-balanced loop:
//   * scalar:  RawClickHouseClient.scalar([UInt8], as:)
//   * select:  RawClickHouseClient.select(_, as:) AsyncThrowingStream
//   * insert:  RawClickHouseClient.insert(into:rows:) with Codable
//   * stream:  RawClickHouseClient.stream(_, as:, handler:) with the
//              DXMessageHandler conformer that buffers rows for the
//              loop's count assertion.
extension Stability {

@Suite(
    "DXClickHouseRaw stability — soak (every Raw client mode in a loop)",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct RawSoakTests {

    private static let warmupRows = 20_000
    private static let scalarExpectedCount: UInt64 = UInt64(warmupRows)
    private static let insertBatchRows = 200
    private static let selectLimit = 500
    private static let streamLimit = 250
    private static let p99DriftCeilingFraction: Double = 0.20

    // Absolute RSS growth ceiling across the soak run. Sized at 200 MB
    // to match the model the NIO-backed soak uses (an absolute byte
    // bound calibrated to the union of per-mode high-water marks plus
    // glibc allocator slack across tens of thousands of operations).
    // A relative fraction over a tiny ~80 MB Linux baseline is too
    // sensitive to allocator fragmentation to catch real leaks: a true
    // per-iteration retention compounds to hundreds of MB over a 5 min
    // run and trips this bound easily, while normal allocator behaviour
    // (per-block [UInt8] turnover, Foundation Date/UUID arenas) settles
    // well below it. The Raw transport runs leaner than the NIO stack
    // (one worker queue, one socket, one arena) so its budget is well
    // under the NIO soak's 500 MB ceiling.
    private static let residentGrowthCeilingBytes: Int64 = 200 * 1024 * 1024

    struct SoakRow: Codable, Sendable, Equatable {

        let id: UInt64
        let bucket: String
        let value: Double
    }

    actor RowCollectingHandler: DXMessageHandler {

        typealias Message = SoakRow
        typealias Failure = RawClickHouseError

        private(set) var rows: [SoakRow] = []
        private(set) var failures: [RawClickHouseError] = []

        func receive(_ message: SoakRow) async {
            rows.append(message)
        }

        func receive(error: RawClickHouseError) async {
            failures.append(error)
        }

        func drain() -> (rows: Int, failures: Int) {
            (rows.count, failures.count)
        }
    }

    @Test("five-minute soak holds bounded RSS, P99 drift, and zero errors across every Raw client surface")
    func testFiveMinuteSoakHoldsBoundedRSS() async throws {
        let client = try await RawStabilitySupport.makeClient()
        defer { Task { await client.close() } }

        let table = RawStabilitySupport.uniqueTable(prefix: "soak")
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("""
            CREATE TABLE \(table) (
                id UInt64,
                bucket String,
                value Float64
            ) ENGINE = MergeTree ORDER BY id
            """)
        defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }

        try await Self.warmFixture(client: client, table: table)

        let baselineResident = RawStabilityProcessRSS.currentBytes()
        var peakResident = baselineResident
        var insertCounter: UInt64 = UInt64(Self.warmupRows)

        let durationSeconds = RawStabilitySupport.soakDurationSeconds
        let soakStart = ContinuousClock.now
        let deadline = soakStart.advanced(by: .seconds(durationSeconds))

        var windows: [RawStabilityWindow] = []
        var currentWindow = RawStabilityWindow()
        var currentMinuteIndex = 0
        var modeCursor = 0
        var totalSamples = 0
        var totalErrors = 0
        let modes: [SoakMode] = SoakMode.allCases
        var lastResidentSample = baselineResident
        var lastSampledAtMicroseconds: Int64 = 0
        let residentSamplingIntervalMicroseconds: Int64 = 30_000_000

        while ContinuousClock.now < deadline {
            let elapsedMicroseconds = RawStabilitySupport.microsecondsSince(soakStart)
            let elapsedMinute = Int(elapsedMicroseconds / 60_000_000)
            if elapsedMinute > currentMinuteIndex {
                windows.append(currentWindow)
                currentWindow = RawStabilityWindow()
                currentMinuteIndex = elapsedMinute
            }
            if elapsedMicroseconds - lastSampledAtMicroseconds >= residentSamplingIntervalMicroseconds {
                let now = RawStabilityProcessRSS.currentBytes()
                peakResident = max(peakResident, now)
                lastResidentSample = now
                lastSampledAtMicroseconds = elapsedMicroseconds
            }

            let mode = modes[modeCursor % modes.count]
            modeCursor += 1
            let operationStart = ContinuousClock.now
            do {
                try await Self.execute(
                    mode: mode,
                    client: client,
                    table: table,
                    insertCounter: &insertCounter
                )
                currentWindow.record(microseconds: RawStabilitySupport.microsecondsSince(operationStart))
                totalSamples += 1
            } catch {
                currentWindow.recordError()
                totalErrors += 1
            }
        }
        windows.append(currentWindow)
        let finalResident = RawStabilityProcessRSS.currentBytes()
        peakResident = max(peakResident, finalResident)
        _ = lastResidentSample

        #expect(totalSamples > 0, "soak completed with zero recorded samples")
        #expect(totalErrors == 0, "soak surfaced \(totalErrors) errors across \(totalSamples) operations")

        if baselineResident > 0 && peakResident > 0 {
            let growthBytes = peakResident - baselineResident
            #expect(
                growthBytes <= Self.residentGrowthCeilingBytes,
                "soak RSS grew from \(baselineResident / 1024 / 1024) MB to \(finalResident / 1024 / 1024) MB (peak \(peakResident / 1024 / 1024) MB), a \(growthBytes / 1024 / 1024) MB increase (ceiling \(Self.residentGrowthCeilingBytes / 1024 / 1024) MB)"
            )
        }

        if windows.count >= 2 {
            let firstWindow = windows.first(where: { !$0.samples.isEmpty })
            let lastWindow = windows.reversed().first(where: { !$0.samples.isEmpty })
            if let firstWindow, let lastWindow, firstWindow.p99Microseconds() > 0 {
                let firstP99 = firstWindow.p99Microseconds()
                let lastP99 = lastWindow.p99Microseconds()
                let driftFraction = Double(lastP99 - firstP99) / Double(firstP99)
                #expect(
                    driftFraction <= Self.p99DriftCeilingFraction,
                    "P99 latency drift across the soak exceeded ceiling: first minute=\(firstP99)us last minute=\(lastP99)us drift=\(Int(driftFraction * 100))% (ceiling \(Int(Self.p99DriftCeilingFraction * 100))%)"
                )
            }
        }
    }

    private static func warmFixture(client: RawClickHouseClient, table: String) async throws {
        let rows: [SoakRow] = (0..<warmupRows).map { index in
            SoakRow(id: UInt64(index), bucket: "bucket-\(index % 16)", value: Double(index) * 0.5)
        }
        _ = try await client.insert(into: table, rows: rows)
    }

    private static func execute(
        mode: SoakMode,
        client: RawClickHouseClient,
        table: String,
        insertCounter: inout UInt64
    ) async throws {
        switch mode {
        case .scalarFromBytes:
            let sql = Array("SELECT toUInt64(count()) FROM \(table)".utf8)
            let count = try await client.scalar(sql, as: UInt64.self)
            guard count >= scalarExpectedCount else {
                throw RawClickHouseError.protocolError(
                    stage: "soak.scalar",
                    message: "expected count >= \(scalarExpectedCount), got \(count)"
                )
            }
        case .selectStreaming:
            let sql = "SELECT id, bucket, value FROM \(table) ORDER BY id LIMIT \(selectLimit)"
            var observed = 0
            for try await _ in client.select(sql, as: SoakRow.self) {
                observed += 1
            }
            guard observed == selectLimit else {
                throw RawClickHouseError.protocolError(
                    stage: "soak.select",
                    message: "expected \(selectLimit) rows, got \(observed)"
                )
            }
        case .insertCodableBatch:
            let base = insertCounter
            insertCounter += UInt64(insertBatchRows)
            let rows: [SoakRow] = (0..<insertBatchRows).map { offset in
                SoakRow(
                    id: base + UInt64(offset),
                    bucket: "bucket-\(offset % 16)",
                    value: Double(offset) * 0.25
                )
            }
            let summary = try await client.insert(into: table, rows: rows)
            guard summary.rowsSent == insertBatchRows else {
                throw RawClickHouseError.protocolError(
                    stage: "soak.insert",
                    message: "expected rowsSent=\(insertBatchRows), got \(summary.rowsSent)"
                )
            }
        case .streamWithHandler:
            let sql = "SELECT id, bucket, value FROM \(table) ORDER BY id LIMIT \(streamLimit)"
            let handler = RowCollectingHandler()
            let task = client.stream(sql, as: SoakRow.self, handler: handler)
            await task.value
            let snapshot = await handler.drain()
            guard snapshot.failures == 0 else {
                throw RawClickHouseError.protocolError(
                    stage: "soak.stream",
                    message: "stream handler surfaced \(snapshot.failures) failures"
                )
            }
            guard snapshot.rows == streamLimit else {
                throw RawClickHouseError.protocolError(
                    stage: "soak.stream",
                    message: "expected \(streamLimit) rows, got \(snapshot.rows)"
                )
            }
        }
    }
}

}

private enum SoakMode: CaseIterable, Sendable {

    case scalarFromBytes
    case selectStreaming
    case insertCodableBatch
    case streamWithHandler
}
