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

// Load test for the block-batched columnar SELECT path. Asserts:
//
//   1. The fast Codable path (`selectStreamFast`) round-trips a
//      200K-row table correctly across 8 concurrent streams.
//   2. The row-builder path (`selectStreamBuilder`) round-trips the
//      same workload correctly across 8 concurrent streams.
//   3. The per-stream P99 latency stays under a generous threshold so
//      a soft regression (e.g. accidental per-row async-stream re-wire)
//      shows up here, not in production.
//
// The thresholds are sized to the slowest reasonable hardware in CI
// (debug build, no optimisation); release-build runs pass in seconds.
@Suite(
    "ClickHouse integration — columnar fast SELECT load",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct ClickHouseColumnarFastSelectLoadTests {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var user: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default" }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }
    private static var database: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "test" }

    private static let streamCount = 8
    // 1M rows × 8 streams × debug-build throughput would take ~5 min
    // in CI. The integration test stays at 200K rows × 8 streams so
    // the per-row data path still drives every code path (block
    // boundary, slot cache hit/miss, async stream yield, multi-block
    // wire dispatch) without paying the full bench duration. The
    // standalone benchmark target carries the headline numbers.
    private static let rowCount = 200_000
    private static let blockRowCount = 100_000
    private static let perStreamP99CeilingSeconds: Double = 120.0

    private static func configuration(eventLoopGroup: EventLoopGroup) -> ClickHouseClient.Configuration {
        .init(
            endpoints: [.init(host: host, port: port)],
            database: database,
            user: user,
            password: password,
            maxConnections: streamCount,
            maxIdleConnections: streamCount,
            eventLoopGroup: eventLoopGroup
        )
    }

    typealias LoadRow = ColumnarFastLoadRow

    private static func seedTable(_ client: ClickHouseClient, table: String) async throws {
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (id UInt64, tag String, value Float64, ts DateTime) ENGINE = MergeTree ORDER BY id")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let totalBlocks = (rowCount + blockRowCount - 1) / blockRowCount
        for blockIndex in 0..<totalBlocks {
            let blockStart = blockIndex * blockRowCount
            let blockEnd = min(blockStart + blockRowCount, rowCount)
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
    }

    private static func uniqueTable(_ kind: String) -> String {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_").prefix(12)
        return "\(database).fast_load_\(kind)_\(suffix)"
    }

    private static func microsecondsSince(_ start: ContinuousClock.Instant) -> Int64 {
        let duration = ContinuousClock.now - start
        let seconds = duration.components.seconds
        let attoseconds = duration.components.attoseconds
        return seconds * 1_000_000 + attoseconds / 1_000_000_000_000
    }

    private static func percentile(_ sortedSamples: [Int64], _ fraction: Double) -> Int64 {
        if sortedSamples.isEmpty { return 0 }
        let lastIndex = sortedSamples.count - 1
        let position = Int((Double(lastIndex) * fraction).rounded())
        return sortedSamples[min(max(position, 0), lastIndex)]
    }

    // Heavyweight 1M-row × 8-stream scenario. Pins the post-H1
    // bulk-string-reader speedup against a regression. The P99
    // ceiling and aggregate throughput targets are sized for the
    // localhost-loop Docker setup the CI runner uses; debug-build
    // local runs typically finish in under 30 seconds.
    private static let heavyRowCount = 1_000_000
    private static let heavyPerStreamP99CeilingSeconds: Double = 240.0
    private static let heavyAggregateRowsPerSecondFloor: Double = 200_000.0

    @Test("selectStreamFast: 1M rows across 8 concurrent streams round-trips correctly, P99 stream-completion latency stays under the regression ceiling, and aggregate throughput stays above the floor")
    func selectStreamFastHeavyLoadEightConcurrentStreams() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 4)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }

        let table = Self.uniqueTable("fast_heavy")
        try await Self.seedHeavyTable(client, table: table)
        defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }

        let wallStart = ContinuousClock.now
        let perStreamLatenciesMicros = try await withThrowingTaskGroup(of: Int64.self, returning: [Int64].self) { group in
            for _ in 0..<Self.streamCount {
                group.addTask {
                    var observed = 0
                    let start = ContinuousClock.now
                    for try await batch in client.selectStreamFast(LoadRow.self, from: "SELECT id, tag, value, ts FROM \(table)") {
                        observed += batch.count
                    }
                    #expect(observed == Self.heavyRowCount, "each heavy stream must observe every row exactly once")
                    return Self.microsecondsSince(start)
                }
            }
            var collected: [Int64] = []
            collected.reserveCapacity(Self.streamCount)
            for try await sample in group {
                collected.append(sample)
            }
            return collected
        }
        let wallMicros = Self.microsecondsSince(wallStart)
        let totalRows = Self.heavyRowCount * Self.streamCount
        let aggregateRowsPerSecond = Double(totalRows) / (Double(wallMicros) / 1_000_000.0)

        var sorted = perStreamLatenciesMicros
        sorted.sort()
        let p99Micros = Self.percentile(sorted, 0.99)
        let p99Seconds = Double(p99Micros) / 1_000_000.0
        #expect(p99Seconds <= Self.heavyPerStreamP99CeilingSeconds, "heavy P99 per-stream completion latency \(p99Seconds)s exceeded ceiling \(Self.heavyPerStreamP99CeilingSeconds)s")
        #expect(aggregateRowsPerSecond >= Self.heavyAggregateRowsPerSecondFloor, "heavy aggregate throughput \(aggregateRowsPerSecond) rows/s fell below floor \(Self.heavyAggregateRowsPerSecondFloor) rows/s")
    }

    private static func seedHeavyTable(_ client: ClickHouseClient, table: String) async throws {
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (id UInt64, tag String, value Float64, ts DateTime) ENGINE = MergeTree ORDER BY id")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let blockSize = 100_000
        let totalBlocks = (heavyRowCount + blockSize - 1) / blockSize
        for blockIndex in 0..<totalBlocks {
            let blockStart = blockIndex * blockSize
            let blockEnd = min(blockStart + blockSize, heavyRowCount)
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
    }

    @Test("selectStreamFast: 200K rows across 8 concurrent streams round-trips correctly and P99 stream-completion latency stays under the regression ceiling")
    func selectStreamFastLoadEightConcurrentStreams() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 4)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }

        let table = Self.uniqueTable("fast")
        try await Self.seedTable(client, table: table)
        defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }

        let perStreamLatenciesMicros = try await withThrowingTaskGroup(of: Int64.self, returning: [Int64].self) { group in
            for _ in 0..<Self.streamCount {
                group.addTask {
                    var observed = 0
                    let start = ContinuousClock.now
                    for try await batch in client.selectStreamFast(LoadRow.self, from: "SELECT id, tag, value, ts FROM \(table)") {
                        observed += batch.count
                    }
                    #expect(observed == Self.rowCount, "each stream must observe every row exactly once")
                    return Self.microsecondsSince(start)
                }
            }
            var collected: [Int64] = []
            collected.reserveCapacity(Self.streamCount)
            for try await sample in group {
                collected.append(sample)
            }
            return collected
        }

        var sorted = perStreamLatenciesMicros
        sorted.sort()
        let p99Micros = Self.percentile(sorted, 0.99)
        let p99Seconds = Double(p99Micros) / 1_000_000.0
        #expect(p99Seconds <= Self.perStreamP99CeilingSeconds, "P99 per-stream completion latency \(p99Seconds)s exceeded ceiling \(Self.perStreamP99CeilingSeconds)s")
    }

    @Test("selectStreamBuilder: 200K rows across 8 concurrent streams round-trips correctly and P99 stream-completion latency stays under the regression ceiling")
    func selectStreamBuilderLoadEightConcurrentStreams() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 4)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }

        let table = Self.uniqueTable("builder")
        try await Self.seedTable(client, table: table)
        defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }

        let perStreamLatenciesMicros = try await withThrowingTaskGroup(of: Int64.self, returning: [Int64].self) { group in
            for _ in 0..<Self.streamCount {
                group.addTask {
                    var observed = 0
                    let start = ContinuousClock.now
                    let cache = LoadRowSlotCache()
                    let stream = client.selectStreamBuilder(LoadRow.self, from: "SELECT id, tag, value, ts FROM \(table)") { block, rowIndex in
                        let slots = cache.ensure(block)
                        return LoadRowSlotCache.extractRow(block: block, slots: slots, rowIndex: rowIndex)
                    }
                    for try await batch in stream {
                        observed += batch.count
                    }
                    #expect(observed == Self.rowCount, "each stream must observe every row exactly once")
                    return Self.microsecondsSince(start)
                }
            }
            var collected: [Int64] = []
            collected.reserveCapacity(Self.streamCount)
            for try await sample in group {
                collected.append(sample)
            }
            return collected
        }

        var sorted = perStreamLatenciesMicros
        sorted.sort()
        let p99Micros = Self.percentile(sorted, 0.99)
        let p99Seconds = Double(p99Micros) / 1_000_000.0
        #expect(p99Seconds <= Self.perStreamP99CeilingSeconds, "P99 per-stream completion latency \(p99Seconds)s exceeded ceiling \(Self.perStreamP99CeilingSeconds)s")
    }

}

struct ColumnarFastLoadRow: Codable, Equatable, Sendable {

    let id: UInt64
    let tag: String
    let value: Double
    let ts: Date

}

// Per-stream slot cache used by the row-builder load test. Lives at
// file scope so the closure capture is a class instance (Sendable)
// rather than a captured `var` (which would not be Sendable across
// the @Sendable boundary of selectStreamBuilder).
private final class LoadRowSlotCache: @unchecked Sendable {

    struct Slots: Sendable {

        let id: Int
        let tag: Int
        let value: Int
        let ts: Int

    }

    private var slots = Slots(id: -1, tag: -1, value: -1, ts: -1)
    private var columnsCount = -1

    func ensure(_ block: ClickHouseSelectBlock) -> Slots {
        if columnsCount == block.columns.count {
            return slots
        }
        slots = Self.resolve(block)
        columnsCount = block.columns.count
        return slots
    }

    private static func resolve(_ block: ClickHouseSelectBlock) -> Slots {
        var idSlot = -1
        var tagSlot = -1
        var valueSlot = -1
        var tsSlot = -1
        for (position, column) in block.columns.enumerated() {
            assignSlot(column.name, position: position, id: &idSlot, tag: &tagSlot, value: &valueSlot, ts: &tsSlot)
        }
        return Slots(id: idSlot, tag: tagSlot, value: valueSlot, ts: tsSlot)
    }

    private static func assignSlot(_ name: String, position: Int, id: inout Int, tag: inout Int, value: inout Int, ts: inout Int) {
        switch name {
        case "id": id = position
        case "tag": tag = position
        case "value": value = position
        case "ts": ts = position
        default: return
        }
    }

    static func extractRow(block: ClickHouseSelectBlock, slots: Slots, rowIndex: Int) -> ColumnarFastLoadRow {
        ColumnarFastLoadRow(
            id: extractUInt64(block.columns[slots.id].values, rowIndex),
            tag: extractString(block.columns[slots.tag].values, rowIndex),
            value: extractDouble(block.columns[slots.value].values, rowIndex),
            ts: extractDateTime(block.columns[slots.ts].values, rowIndex)
        )
    }

    private static func extractUInt64(_ values: ClickHouseColumnEntry.Values, _ rowIndex: Int) -> UInt64 {
        if case .uint64(let arr) = values { return arr[rowIndex] }
        return 0
    }

    private static func extractString(_ values: ClickHouseColumnEntry.Values, _ rowIndex: Int) -> String {
        if case .string(let arr) = values { return arr[rowIndex] }
        return ""
    }

    private static func extractDouble(_ values: ClickHouseColumnEntry.Values, _ rowIndex: Int) -> Double {
        if case .float64(let arr) = values { return arr[rowIndex] }
        return 0
    }

    private static func extractDateTime(_ values: ClickHouseColumnEntry.Values, _ rowIndex: Int) -> Date {
        if case .dateTime(let arr) = values { return arr[rowIndex] }
        return Date(timeIntervalSince1970: 0)
    }

}
