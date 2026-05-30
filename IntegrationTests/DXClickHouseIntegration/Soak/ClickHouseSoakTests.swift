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

@testable import DXClickHouse
import Foundation
import NIOCore
import NIOPosix
import Testing

// Sustained-load soak test. Runs every real-workload mode in a round-
// robin loop for the configured duration (60s default, 600s "full"
// run via CH_SOAK_DURATION_SECONDS=600) against a shared live cluster
// and asserts four invariants:
//
//   1. No memory growth — process RSS remains bounded across the
//      run; a leak in the streaming hot path would push RSS up
//      linearly with operation count.
//   2. No connection-pool exhaustion — pool waiter count is zero
//      at every minute boundary and at completion.
//   3. No P99 latency creep — minute-by-minute P99 stays within 20%
//      of the first minute's P99 (per spec). Drift above that bound
//      indicates a steady-state degradation (lock contention,
//      retained-block growth, GC-style stutter) that the per-mode
//      bench would not catch on a 100k-row burst.
//   4. No error rate spike — total error count stays at zero. A
//      single transient error during the soak is a defect that
//      must be investigated before release.
//
// The "real-workload modes" mirror the bench mode catalogue: small
// SELECT, columnar bulk SELECT, fast Codable SELECT, scalar SELECT,
// columnar INSERT, Codable INSERT, LowCardinality+Map INSERT,
// LowCardinality+Map SELECT, and ORDER BY+LIMIT/GROUP BY/WHERE-IN
// real-shape queries. Each mode runs one operation per round-trip
// of the loop; the loop cycles until the wall clock crosses the
// configured duration.
@Suite(
    "ClickHouse integration — soak (every real-workload mode in a loop)",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct ClickHouseSoakTests {

    private static let warmupRows = 20_000
    private static let bulkBatchRows = 2_000
    private static let lcMapBatchRows = 1_000
    private static let topTags = 64

    // P99 minute-over-minute drift ceiling. Per spec, P99 at the last
    // minute must sit within 20% of P99 at the first minute. The bound
    // catches a real degradation while tolerating the noise floor of
    // a localhost loop (sub-millisecond Linux scheduler jitter).
    private static let p99DriftCeilingFraction: Double = 0.20

    // RSS growth ceiling across the whole soak run. Sized at 500 MB
    // because the soak fires every real-workload mode in round-robin
    // (bulk SELECT, columnar INSERT, LC+Map INSERT/SELECT, GROUP BY,
    // WHERE-IN, ORDER BY LIMIT) and the Linux glibc allocator holds
    // the union of per-mode high-water marks across the run. A real
    // per-iteration leak in the streaming hot path would compound to
    // GB-scale over a 60s run and trip this bound; allocator slack
    // sits well below it.
    private static let residentGrowthCeilingBytes: Int64 = 500 * 1024 * 1024

    @Test("soak: every real-workload mode looped for the configured duration holds bounded RSS, pool, P99 drift, and error rate at zero")
    func realWorkloadSoakRespectsAllStabilityInvariants() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 4)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: SoakTestSupport.makeConfiguration(
            eventLoopGroup: group,
            maxConnections: 8,
            endpoints: SoakTestSupport.defaultEndpoints()
        ))
        defer { Task { await client.shutdown() } }

        let baseTable = SoakTestSupport.uniqueTable("base")
        let lcTable = SoakTestSupport.uniqueTable("lc")
        try await client.execute("DROP TABLE IF EXISTS \(baseTable)")
        try await client.execute("CREATE TABLE \(baseTable) (id UInt64, tag String, value Float64, ts DateTime) ENGINE = MergeTree ORDER BY id")
        try await client.execute("DROP TABLE IF EXISTS \(lcTable)")
        try await client.execute("CREATE TABLE \(lcTable) (id UInt64, route LowCardinality(String), labels Map(LowCardinality(String), String)) ENGINE = MergeTree ORDER BY id")
        defer {
            Task {
                try? await client.execute("DROP TABLE IF EXISTS \(baseTable)")
                try? await client.execute("DROP TABLE IF EXISTS \(lcTable)")
            }
        }

        try await Self.warmFixture(client: client, baseTable: baseTable, lcTable: lcTable)

        let baselineResident = ProcessRSS.currentBytes()
        var peakResident = baselineResident

        let duration = SoakTestSupport.soakDurationSeconds
        let soakStart = ContinuousClock.now
        let deadline = soakStart.advanced(by: .seconds(duration))

        var windows: [SoakWindow] = []
        var currentWindow = SoakWindow()
        var currentMinuteIndex = 0
        var rowCounter = UInt64(Self.warmupRows)
        var modeCursor = 0
        var poolWaiterPeak = 0

        while ContinuousClock.now < deadline {
            let elapsedMinute = Int(SoakTestSupport.microsecondsSince(soakStart) / 60_000_000)
            if elapsedMinute > currentMinuteIndex {
                windows.append(currentWindow)
                currentWindow = SoakWindow()
                currentMinuteIndex = elapsedMinute
                peakResident = max(peakResident, ProcessRSS.currentBytes())
                let stats = await client.poolStats()
                poolWaiterPeak = max(poolWaiterPeak, stats.waiterCount)
            }

            let mode = SoakMode.all[modeCursor % SoakMode.all.count]
            modeCursor += 1
            let opStart = ContinuousClock.now
            do {
                try await Self.execute(mode: mode, client: client, baseTable: baseTable, lcTable: lcTable, rowCounter: &rowCounter)
                currentWindow.record(microseconds: SoakTestSupport.microsecondsSince(opStart))
            } catch {
                currentWindow.recordError()
            }
        }
        windows.append(currentWindow)
        peakResident = max(peakResident, ProcessRSS.currentBytes())

        let finalPoolStats = await client.poolStats()
        let totalSamples = windows.reduce(0) { $0 + $1.samples.count }
        let totalErrors = windows.reduce(0) { $0 + $1.errors }

        #expect(totalErrors == 0, "soak surfaced \(totalErrors) errors across \(totalSamples) operations")
        #expect(finalPoolStats.waiterCount == 0, "pool waiter count was \(finalPoolStats.waiterCount) at completion")
        #expect(poolWaiterPeak == 0, "pool waiter peak across the run was \(poolWaiterPeak); pool was saturated mid-run")

        if baselineResident > 0 {
            let growth = Int64(peakResident) - Int64(baselineResident)
            #expect(
                growth < Self.residentGrowthCeilingBytes,
                "soak RSS grew by \(growth / 1024 / 1024) MB across \(totalSamples) operations (ceiling \(Self.residentGrowthCeilingBytes / 1024 / 1024) MB) — likely streaming-path retention"
            )
        }

        if windows.count >= 2 {
            let firstP99 = windows[0].p99Microseconds()
            let lastP99 = windows[windows.count - 1].p99Microseconds()
            if firstP99 > 0 {
                let drift = Double(lastP99 - firstP99) / Double(firstP99)
                #expect(
                    drift <= Self.p99DriftCeilingFraction,
                    "P99 latency at minute \(windows.count - 1) (\(lastP99)us) exceeded minute 0 (\(firstP99)us) by \(Int(drift * 100))% (ceiling \(Int(Self.p99DriftCeilingFraction * 100))%)"
                )
            }
        }

        #expect(totalSamples > 0, "soak completed with zero recorded samples — the loop did not execute any operations")
    }

    private static func warmFixture(client: ClickHouseClient, baseTable: String, lcTable: String) async throws {
        let ids = (0..<warmupRows).map { UInt64($0) }
        let tags = (0..<warmupRows).map { "tag-\($0 % topTags)" }
        let values = (0..<warmupRows).map { Double($0) * 0.5 }
        let timestamps = Array(repeating: Date(timeIntervalSince1970: 1_700_000_000), count: warmupRows)
        try await client.insert(into: baseTable, columns: [
            .init(name: "id", values: .uint64(ids)),
            .init(name: "tag", values: .string(tags)),
            .init(name: "value", values: .float64(values)),
            .init(name: "ts", values: .dateTime(timestamps)),
        ])

        let lcIds = (0..<lcMapBatchRows).map { UInt64($0) }
        let routes = (0..<lcMapBatchRows).map { "route-\($0 % 8)" }
        let labels: [[String: String]] = (0..<lcMapBatchRows).map { rowIndex in
            [
                "env": rowIndex.isMultiple(of: 2) ? "prod" : "stage",
                "region": "us-east-\(rowIndex % 4)",
            ]
        }
        try await client.insert(into: lcTable, columns: [
            .init(name: "id", values: .uint64(lcIds)),
            .init(name: "route", values: .lowCardinalityString(routes)),
            .init(name: "labels", values: .mapStringString(labels)),
        ])
    }

    private static func execute(
        mode: SoakMode,
        client: ClickHouseClient,
        baseTable: String,
        lcTable: String,
        rowCounter: inout UInt64
    ) async throws {
        switch mode {
        case .scalarSelect:
            _ = try await client.scalarInt64("SELECT toInt64(count()) FROM \(baseTable)")
        case .smallSelect:
            let batches: [[SoakRow]] = try await Self.collect(client.selectStreamFast(
                SoakRow.self,
                from: "SELECT id, tag, value FROM \(baseTable) WHERE id < 1000 ORDER BY id"
            ))
            _ = batches.reduce(0) { $0 + $1.count }
        case .bulkColumnarSelect:
            let blocks = client.selectColumns("SELECT id, tag, value, ts FROM \(baseTable) ORDER BY id LIMIT 10000")
            var seen = 0
            for try await block in blocks { seen += block.rowCount }
            _ = seen
        case .bulkFastSelect:
            let batches: [[SoakRow]] = try await Self.collect(client.selectStreamFast(
                SoakRow.self,
                from: "SELECT id, tag, value FROM \(baseTable) LIMIT 10000"
            ))
            _ = batches.reduce(0) { $0 + $1.count }
        case .orderByLimit:
            let batches: [[SoakOrderRow]] = try await Self.collect(client.selectStreamFast(
                SoakOrderRow.self,
                from: "SELECT id, value FROM \(baseTable) ORDER BY value DESC LIMIT 200"
            ))
            _ = batches.reduce(0) { $0 + $1.count }
        case .groupBy:
            let blocks = client.selectColumns("SELECT tag, count() c FROM \(baseTable) GROUP BY tag ORDER BY tag LIMIT 64")
            var seen = 0
            for try await block in blocks { seen += block.rowCount }
            _ = seen
        case .whereIn:
            let blocks = client.selectColumns("SELECT id, value FROM \(baseTable) WHERE tag IN ('tag-0','tag-1','tag-2') LIMIT 5000")
            var seen = 0
            for try await block in blocks { seen += block.rowCount }
            _ = seen
        case .columnarInsert:
            let base = Int(rowCounter)
            rowCounter += UInt64(bulkBatchRows)
            let ids = (base..<(base + bulkBatchRows)).map { UInt64($0) }
            let tags = (base..<(base + bulkBatchRows)).map { "tag-\($0 % topTags)" }
            let values = (base..<(base + bulkBatchRows)).map { Double($0) * 0.5 }
            let timestamps = Array(repeating: Date(timeIntervalSince1970: 1_700_000_000), count: bulkBatchRows)
            try await client.insert(into: baseTable, columns: [
                .init(name: "id", values: .uint64(ids)),
                .init(name: "tag", values: .string(tags)),
                .init(name: "value", values: .float64(values)),
                .init(name: "ts", values: .dateTime(timestamps)),
            ])
        case .lcMapInsert:
            let base = Int(rowCounter)
            rowCounter += UInt64(lcMapBatchRows)
            let ids = (base..<(base + lcMapBatchRows)).map { UInt64($0) }
            let routes = (base..<(base + lcMapBatchRows)).map { "route-\($0 % 8)" }
            let labels: [[String: String]] = (base..<(base + lcMapBatchRows)).map { rowIndex in
                [
                    "env": rowIndex.isMultiple(of: 2) ? "prod" : "stage",
                    "region": "us-east-\(rowIndex % 4)",
                ]
            }
            try await client.insert(into: lcTable, columns: [
                .init(name: "id", values: .uint64(ids)),
                .init(name: "route", values: .lowCardinalityString(routes)),
                .init(name: "labels", values: .mapStringString(labels)),
            ])
        case .lcMapSelect:
            let blocks = client.selectColumns("SELECT id, route FROM \(lcTable) LIMIT 1000")
            var seen = 0
            for try await block in blocks { seen += block.rowCount }
            _ = seen
        case .stringColumnView:
            // Zero-allocation String column view path against the seed
            // table. Walks every row of `tag` through the arena-backed
            // view and counts UTF-8 bytes without materialising a
            // Swift String per row.
            let stream = client.selectStringColumns("SELECT tag FROM \(baseTable) LIMIT 5000")
            var bytes = 0
            for try await block in stream {
                if case .present(let column) = block.stringColumn(named: "tag") {
                    column.forEach { _, view in bytes += view.utf8Length }
                }
            }
            _ = bytes
        case .lcMapColumnView:
            // Map(LowCardinality, String) column-view path. Reads
            // `labels` through the arena and counts pairs in place.
            let stream = client.selectStringColumns("SELECT labels FROM \(lcTable) LIMIT 1000")
            var pairs = 0
            for try await block in stream {
                if case .present(let column) = block.mapStringStringColumn(named: "labels") {
                    for rowIndex in 0..<column.rowCount {
                        pairs += column.view(at: rowIndex).count
                    }
                }
            }
            _ = pairs
        case .rowsBuilderView:
            // selectRowsBuilder view path. Hands the row builder a
            // BlockStringView, builds a (id, tag-byte-count) pair per
            // row, sums byte counts. No per-row String allocation.
            let stream = client.selectRowsBuilder(
                SoakViewBuilderRow.self,
                from: "SELECT id, tag FROM \(baseTable) WHERE id < 5000 ORDER BY id"
            ) { block, rowIndex in
                let id = block.fixedStringColumns.first
                _ = id
                let tagBytes: Int
                if case .present(let column) = block.stringColumn(named: "tag") {
                    tagBytes = column.view(at: rowIndex).utf8Length
                } else {
                    tagBytes = 0
                }
                return SoakViewBuilderRow(tagBytes: tagBytes)
            }
            var totalBytes = 0
            for try await batch in stream {
                for row in batch { totalBytes += row.tagBytes }
            }
            _ = totalBytes
        }
    }

    private static func collect<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>) async throws -> [T] {
        var out: [T] = []
        for try await element in stream {
            out.append(element)
        }
        return out
    }

}

private enum SoakMode: Sendable {

    case scalarSelect
    case smallSelect
    case bulkColumnarSelect
    case bulkFastSelect
    case orderByLimit
    case groupBy
    case whereIn
    case columnarInsert
    case lcMapInsert
    case lcMapSelect
    case stringColumnView
    case lcMapColumnView
    case rowsBuilderView

    static let all: [SoakMode] = [
        .scalarSelect, .smallSelect, .bulkColumnarSelect, .bulkFastSelect,
        .orderByLimit, .groupBy, .whereIn,
        .columnarInsert, .lcMapInsert, .lcMapSelect,
        .stringColumnView, .lcMapColumnView, .rowsBuilderView,
    ]

}

private struct SoakRow: Decodable, Sendable {

    let id: UInt64
    let tag: String
    let value: Double
}

private struct SoakOrderRow: Decodable, Sendable {

    let id: UInt64
    let value: Double
}

private struct SoakViewBuilderRow: Sendable {

    let tagBytes: Int
}
