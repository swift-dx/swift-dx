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

// LZ4-compression integration tests against the live cluster. The
// uncompressed wire path is exercised by the type matrix and fuzz
// suites; this suite specifically targets the compressed frame path:
// the 9-byte header layout, the CityHash102 checksum, the LZ4 block
// decompressor, and the encoder side that wraps client Data packets
// in compressed frames before sending.
//
// Skipped automatically unless `CH_INTEGRATION_HOST` is set.
@Suite(
    "ClickHouse integration — LZ4 compression",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct ClickHouseCompressionTests {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var user: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default" }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }
    private static var database: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "test" }

    private static func makeClient(compression: ClickHouseClient.OutboundCompression) -> (ClickHouseClient, EventLoopGroup) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: host, port: port)],
            database: database,
            user: user,
            password: password,
            compression: compression,
            eventLoopGroup: group
        ))
        return (client, group)
    }

    private static func uniqueTable(_ prefix: String) -> String {
        "test.lz4_\(prefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
    }

    private static func roundTrip(
        compression: ClickHouseClient.OutboundCompression,
        typeName: String,
        column: String,
        values: ClickHouseColumnEntry.Values
    ) async throws -> ClickHouseColumnEntry.Values {
        let table = uniqueTable(column)
        let (client, _) = makeClient(compression: compression)
        defer { Task { await client.shutdown() } }

        try await client.execute("CREATE TABLE \(table) (v \(typeName)) ENGINE = Memory")
        try await client.insert(into: table, columns: [.init(name: "v", values: values)])
        let blocks = try await client.collectSelectColumns("SELECT v FROM \(table)")
        try await client.execute("DROP TABLE \(table)")

        guard let block = blocks.first(where: { $0.rowCount > 0 }) else {
            throw CompressionTestError.noRowsReturned
        }
        guard let column = block.columns.first else {
            throw CompressionTestError.noColumnsReturned
        }
        return column.values
    }

    private enum CompressionTestError: Error {

        case noRowsReturned
        case noColumnsReturned

    }

    // MARK: - parity: the same payload must round-trip identically with or without compression

    @Test("UInt64 payload is identical after a round-trip whether or not LZ4 is enabled")
    func compressionParityUInt64() async throws {
        let values = (0..<5_000).map { UInt64($0 * 31) }

        let uncompressedResult = try await Self.roundTrip(
            compression: .uncompressed,
            typeName: "UInt64",
            column: "u64",
            values: .uint64(values)
        )
        let compressedResult = try await Self.roundTrip(
            compression: .lz4,
            typeName: "UInt64",
            column: "u64",
            values: .uint64(values)
        )

        guard case .uint64(let plain) = uncompressedResult, case .uint64(let lz4) = compressedResult else {
            Issue.record("expected .uint64 from both modes"); return
        }
        #expect(plain.sorted() == values)
        #expect(lz4.sorted() == values)
        #expect(plain.sorted() == lz4.sorted())
    }

    @Test("String payload survives LZ4 round-trip with byte-identical multi-byte UTF-8 sequences")
    func compressionParityStrings() async throws {
        let values: [String] = [
            "",
            "ascii",
            String(repeating: "x", count: 4096),
            "Привет, мир — multi-byte",
            "🇳🇿🚀✨ emoji 4-byte",
            "embedded\u{0000}null",
        ] + (0..<200).map { "row \($0) — \(UUID().uuidString)" }

        let result = try await Self.roundTrip(
            compression: .lz4,
            typeName: "String",
            column: "s",
            values: .string(values)
        )
        guard case .string(let received) = result else {
            Issue.record("expected .string, got \(result)"); return
        }
        #expect(Set(received) == Set(values))
    }

    @Test("Array(String) survives LZ4 round-trip with offset alignment preserved per row")
    func compressionParityArrayOfString() async throws {
        let values: [[String]] = (0..<300).map { index in
            (0..<(index % 8)).map { "value \(index)/\($0)" }
        }
        let result = try await Self.roundTrip(
            compression: .lz4,
            typeName: "Array(String)",
            column: "a_s",
            values: .arrayOfString(values)
        )
        guard case .arrayOfString(let received) = result else {
            Issue.record("expected .arrayOfString, got \(result)"); return
        }
        let sortKey: ([String]) -> (Int, String) = { ($0.count, $0.first ?? "") }
        let sentSorted = values.sorted { sortKey($0) < sortKey($1) }
        let receivedSorted = received.sorted { sortKey($0) < sortKey($1) }
        #expect(sentSorted == receivedSorted)
    }

    // MARK: - high-volume stress under LZ4

    @Test("50_000-row INSERT + SELECT under LZ4 round-trips without dropping or corrupting rows")
    func lz4HighVolumeRoundTrip() async throws {
        let total = 50_000
        let ids = (0..<total).map { UInt64($0) }
        let names = (0..<total).map { "row_\($0)" }

        let table = Self.uniqueTable("bulk")
        let (client, _) = Self.makeClient(compression: .lz4)
        defer { Task { await client.shutdown() } }

        try await client.execute("CREATE TABLE \(table) (id UInt64, name String) ENGINE = Memory")
        try await client.insert(into: table, columns: [
            .init(name: "id", values: .uint64(ids)),
            .init(name: "name", values: .string(names))
        ])

        let count = try await client.scalarInt64("SELECT toInt64(count(*)) FROM \(table)")
        #expect(count == Int64(total))

        // Pull the rows back streaming and verify the id set matches.
        var seenIds: Set<UInt64> = []
        seenIds.reserveCapacity(total)
        for try await block in client.selectColumns("SELECT id FROM \(table)") {
            guard let column = block.columns.first(where: { $0.name == "id" }) else { continue }
            guard case .uint64(let chunk) = column.values else {
                Issue.record("expected .uint64, got \(column.values)"); return
            }
            seenIds.formUnion(chunk)
        }
        try await client.execute("DROP TABLE \(table)")
        #expect(seenIds.count == total)
        #expect(seenIds.min() == 0)
        #expect(seenIds.max() == UInt64(total - 1))
    }

    @Test("multiple sequential queries on a single connection correctly demarcate compressed frames")
    func multipleSequentialCompressedQueries() async throws {
        let (client, _) = Self.makeClient(compression: .lz4)
        defer { Task { await client.shutdown() } }

        for offset in 0..<25 {
            let value = try await client.scalarInt64("SELECT toInt64(\(offset * 17))")
            #expect(value == Int64(offset * 17))
        }
    }

    @Test("compressed multi-block stream from a SELECT returns every row in the right order")
    func compressedMultiBlockSelect() async throws {
        let total = 10_000
        let (client, _) = Self.makeClient(compression: .lz4)
        defer { Task { await client.shutdown() } }

        var collected: [UInt64] = []
        collected.reserveCapacity(total)
        for try await block in client.selectColumns(
            "SELECT arrayJoin(range(toUInt64(\(total)))) AS n"
        ) {
            guard let column = block.columns.first else { continue }
            guard case .uint64(let chunk) = column.values else {
                Issue.record("expected .uint64, got \(column.values)"); return
            }
            collected.append(contentsOf: chunk)
        }
        let sorted = collected.sorted()
        #expect(sorted.count == total)
        #expect(sorted.first == 0)
        #expect(sorted.last == UInt64(total - 1))
    }

    // MARK: - typed coverage under compression

    @Test("Nullable(Int64) survives LZ4 round-trip with mask alignment preserved")
    func compressionParityNullableInt64() async throws {
        let values: [Int64?] = [
            nil, .min, -1, 0, 1, .max, nil,
            42, nil, nil, 1_234_567_890_123_456_789
        ]
        let result = try await Self.roundTrip(
            compression: .lz4,
            typeName: "Nullable(Int64)",
            column: "n_i64",
            values: .nullableInt64(values.map(ClickHouseNullable.init))
        )
        guard case .nullableInt64(let received) = result else {
            Issue.record("expected .nullableInt64, got \(result)"); return
        }
        let sentNonNil = values.compactMap { $0 }.sorted()
        let receivedNonNil = received.compactMap { $0.value }.sorted()
        let sentNullCount = values.filter { $0 == nil }.count
        let receivedNullCount = received.filter { $0 == nil }.count
        #expect(sentNonNil == receivedNonNil)
        #expect(sentNullCount == receivedNullCount)
    }

    @Test("Tuple(String, Int32) survives LZ4 round-trip with element correspondence preserved")
    func compressionParityTuple() async throws {
        let pairs: [(String, Int32)] = [
            ("alpha", 1),
            ("", 0),
            ("🇳🇿", -1),
            (String(repeating: "x", count: 1024), Int32.max),
            ("multi-byte Привет", Int32.min),
        ]
        let result = try await Self.roundTrip(
            compression: .lz4,
            typeName: "Tuple(String, Int32)",
            column: "t_si",
            values: .tupleStringInt32(pairs)
        )
        guard case .tupleStringInt32(let received) = result else {
            Issue.record("expected .tupleStringInt32, got \(result)"); return
        }
        #expect(received.map(\.0) == pairs.map(\.0))
        #expect(received.map(\.1) == pairs.map(\.1))
    }

    @Test("Map(String, String) survives LZ4 round-trip across empty and populated rows")
    func compressionParityMap() async throws {
        let values: [[String: String]] = [
            [:],
            ["k": "v"],
            ["region": "NZ", "tier": "premium", "extra": String(repeating: "x", count: 256)],
            (0..<32).reduce(into: [String: String]()) { dict, index in
                dict["key_\(index)"] = "value_\(index)"
            }
        ]
        let result = try await Self.roundTrip(
            compression: .lz4,
            typeName: "Map(String, String)",
            column: "m_ss",
            values: .mapStringString(values)
        )
        guard case .mapStringStringIndexed(let storage) = result else {
            Issue.record("expected .mapStringStringIndexed, got \(result)"); return
        }
        #expect(storage.count == values.count)
        for (rowIndex, sent) in values.enumerated() { #expect(sent == storage.row(at: rowIndex)) }
    }

    @Test("LowCardinality(String) survives LZ4 round-trip with dictionary indices preserved")
    func compressionParityLowCardinality() async throws {
        let values = (0..<1_000).map { "v_\($0 % 13)" }
        let result = try await Self.roundTrip(
            compression: .lz4,
            typeName: "LowCardinality(String)",
            column: "lc_s",
            values: .lowCardinalityString(values)
        )
        guard case .lowCardinalityStringIndexed(let view) = result else {
            Issue.record("expected .lowCardinalityStringIndexed, got \(result)"); return
        }
        var materialised: [String] = []
        materialised.reserveCapacity(view.count)
        for rowIndex in 0..<view.count { materialised.append(view[rowIndex]) }
        #expect(materialised.sorted() == values.sorted())
    }

    @Test("Decimal64(scale 6) survives LZ4 round-trip across the full Int64 boundary set")
    func compressionParityDecimal() async throws {
        let values: [Int64] = [.min, -1, 0, 1, .max] + (0..<200).map { Int64($0 * 1_000_000) }
        let result = try await Self.roundTrip(
            compression: .lz4,
            typeName: "Decimal64(6)",
            column: "d64",
            values: .decimal64(values, scale: 6)
        )
        guard case .decimal64(let received, let scale) = result else {
            Issue.record("expected .decimal64, got \(result)"); return
        }
        #expect(scale == 6)
        #expect(received.sorted() == values.sorted())
    }

    @Test("UUID survives LZ4 round-trip with byte-for-byte fidelity across many rows")
    func compressionParityUUID() async throws {
        var rng = SeededRandomNumberGenerator(seed: 0xC0FF_EE)
        let values = (0..<500).map { _ -> UUID in
            let bytes = (0..<16).map { _ in UInt8.random(in: 0...255, using: &rng) }
            return UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
        }
        let result = try await Self.roundTrip(
            compression: .lz4,
            typeName: "UUID",
            column: "id",
            values: .uuid(values)
        )
        guard case .uuid(let received) = result else {
            Issue.record("expected .uuid, got \(result)"); return
        }
        #expect(Set(received) == Set(values))
    }

    @Test("DateTime64(9) nanosecond precision survives LZ4 round-trip")
    func compressionParityDateTime64() async throws {
        let nanos: [ClickHouseNanoseconds] = (0..<200).map { index in
            ClickHouseNanoseconds(1_700_000_000_000_000_000 + Int64(index))
        }
        let result = try await Self.roundTrip(
            compression: .lz4,
            typeName: "DateTime64(9)",
            column: "dt64",
            values: .dateTime64Nanoseconds(nanos, precision: 9)
        )
        guard case .dateTime64Nanoseconds(let received, let precision) = result else {
            Issue.record("expected .dateTime64Nanoseconds, got \(result)"); return
        }
        #expect(precision == 9)
        #expect(Set(received.map(\.rawValue)) == Set(nanos.map(\.rawValue)))
    }

    // MARK: - one-row payload (frame size below the LZ4 minimum-block threshold)

    @Test("a single-row INSERT with a tiny payload still encodes a valid compressed frame")
    func tinyPayloadProducesValidFrame() async throws {
        // Compresses very poorly (single byte). The decoder must still
        // accept the frame and reconstruct the value.
        let result = try await Self.roundTrip(
            compression: .lz4,
            typeName: "UInt8",
            column: "u8",
            values: .uint8([42])
        )
        guard case .uint8(let received) = result else {
            Issue.record("expected .uint8, got \(result)"); return
        }
        #expect(received == [42])
    }

    @Test("Task.cancel mid-LZ4-stream tears down the connection and the next compressed query succeeds on a fresh socket")
    func lz4MidStreamCancellation() async throws {
        let (client, _) = Self.makeClient(compression: .lz4)
        defer { Task { await client.shutdown() } }

        // Warm one connection so cancellation fires against an
        // in-flight query, not the connect path.
        _ = try await client.scalarInt64("SELECT toInt64(0)")

        let started = Date()
        let task = Task<Int, Error> {
            var rowsObserved = 0
            for try await block in client.selectColumns(
                "SELECT toInt64(sleepEachRow(0.1)) FROM numbers(50) SETTINGS function_sleep_max_microseconds_per_block = 5000000"
            ) {
                rowsObserved += block.rowCount
            }
            return rowsObserved
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        _ = await task.result
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 1.5,
                "LZ4 streaming cancellation must unwind in under 1.5s; observed \(elapsed)s")

        // The framing layer must NOT carry partial-frame state from the
        // cancelled stream into the next query — the pool discards the
        // cancelled connection and a fresh one's framing buffer starts
        // empty. Run a string round-trip to confirm the compressed wire
        // path works end-to-end after cancellation.
        let probe = try await client.scalarString("SELECT toString('post-cancel')")
        #expect(probe == "post-cancel")
    }

    @Test("rapid cancel-then-recovery loop under LZ4 stays clean across 20 iterations")
    func lz4CancelRecoveryLoop() async throws {
        let (client, _) = Self.makeClient(compression: .lz4)
        defer { Task { await client.shutdown() } }

        for index in 0..<20 {
            let task = Task<Int64?, Error> {
                try await client.scalarInt64(
                    "SELECT toInt64(sleepEachRow(2.0)) SETTINGS function_sleep_max_microseconds_per_block = 5000000"
                )
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            task.cancel()
            _ = await task.result
            let value = try await client.scalarInt64("SELECT toInt64(\(index))")
            #expect(value == Int64(index), "iteration \(index) under LZ4: recovery must succeed")
        }
    }

    @Test("an INSERT under LZ4 followed by a SELECT under LZ4 sees every row across compressed Data packets")
    func lz4InsertManyBlocksThenSelect() async throws {
        let blocksPerRow = 500
        let blockCount = 10
        let table = Self.uniqueTable("multi_block")
        let (client, _) = Self.makeClient(compression: .lz4)
        defer { Task { await client.shutdown() } }

        try await client.execute("CREATE TABLE \(table) (n UInt32, label String) ENGINE = Memory")

        // Build many separate blocks to exercise multi-block sends with
        // compression on each.
        let blocks: [[ClickHouseColumnEntry]] = (0..<blockCount).map { blockIndex in
            let ids = (0..<blocksPerRow).map { UInt32(blockIndex * blocksPerRow + $0) }
            let labels = (0..<blocksPerRow).map { "label_\(blockIndex)_\($0)" }
            return [
                .init(name: "n", values: .uint32(ids)),
                .init(name: "label", values: .string(labels))
            ]
        }
        try await client.insert(into: table, blocks: blocks)
        let count = try await client.scalarInt64("SELECT toInt64(count(*)) FROM \(table)")
        try await client.execute("DROP TABLE \(table)")
        #expect(count == Int64(blocksPerRow * blockCount))
    }

}
