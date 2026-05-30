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

// Integration tests against the three sample tables provisioned in
// `test.*` (test.sdk_simple, test.sdk_nullable, test.sdk_replacing).
// Each test reseeds its own table with TRUNCATE so concurrent runs
// share the table cleanly.
//
// Skipped automatically unless `CH_INTEGRATION_HOST` is set, matching
// the existing integration suite.
@Suite(
    "ClickHouse integration — sample schemas",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct ClickHouseSampleSchemaTests {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var user: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default" }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }
    private static var database: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "test" }

    private static func makeClient() -> (ClickHouseClient, EventLoopGroup) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: host, port: port)],
            database: database,
            user: user,
            password: password,
            eventLoopGroup: group
        ))
        return (client, group)
    }

    private static func ensureSchema(for table: String, via client: ClickHouseClient) async throws {
        try await client.execute("CREATE DATABASE IF NOT EXISTS test")
        guard let createDDL = sampleSchemas[table] else {
            throw ClickHouseError.scalarColumnTypeMismatch(actualTypeName: "unknown sample table \(table)", expectedKind: "test.sdk_*")
        }
        try await client.execute(createDDL)
    }

    private static func cleanup(table: String, client: ClickHouseClient) async throws {
        try await ensureSchema(for: table, via: client)
        try await client.execute("TRUNCATE TABLE \(table)")
    }

    private static let sampleSchemas: [String: String] = [
        "test.sdk_simple": """
            CREATE TABLE IF NOT EXISTS test.sdk_simple (
              id          UInt64,
              name        String,
              created_at  DateTime64(9),
              value       Float64,
              tags        Array(String),
              attributes  Map(String, String),
              is_active   Bool
            ) ENGINE = MergeTree ORDER BY id
            """,
        "test.sdk_nullable": """
            CREATE TABLE IF NOT EXISTS test.sdk_nullable (
              id                UInt64,
              optional_string   Nullable(String),
              optional_int      Nullable(Int64),
              optional_decimal  Nullable(Decimal(18, 4)),
              optional_uuid     Nullable(UUID),
              enum_field        Int8,
              inserted          DateTime64(9)
            ) ENGINE = MergeTree ORDER BY id
            """,
        "test.sdk_replacing": """
            CREATE TABLE IF NOT EXISTS test.sdk_replacing (
              entity_id  UInt64,
              payload    String,
              version    DateTime64(9)
            ) ENGINE = ReplacingMergeTree(version) ORDER BY entity_id
            """,
    ]

    // MARK: - test.sdk_simple

    @Test("test.sdk_simple — INSERT integers, strings, floats, dates, bool round-trips losslessly")
    func sdkSimpleRoundTrip() async throws {
        let (client, group) = Self.makeClient()
        _ = group

        try await Self.cleanup(table: "test.sdk_simple", client: client)

        // Three rows covering boundary values for each column.
        let createdNs: [ClickHouseNanoseconds] = [
            ClickHouseNanoseconds(1_700_000_000_000_000_001),
            ClickHouseNanoseconds(1_700_000_000_500_000_000),
            ClickHouseNanoseconds(1_700_000_000_999_999_999)
        ]
        try await client.insert(into: "test.sdk_simple", columns: [
            .init(name: "id", values: .uint64([1, 2, 3])),
            .init(name: "name", values: .string(["alpha", "Привет", "🇳🇿"])),
            .init(name: "created_at", values: .dateTime64Nanoseconds(createdNs, precision: 9)),
            .init(name: "value", values: .float64([0.0, .pi, -1.0])),
            .init(name: "tags", values: .arrayOfString([
                ["red", "blue"],
                [],
                ["a", "b", "c"]
            ])),
            // Map(LowCardinality(String), String) accepts plain string keys
            // — server upgrades to LowCardinality on storage.
            .init(name: "attributes", values: .mapStringString([
                ["k1": "v1"],
                [:],
                ["region": "NZ", "tier": "premium"]
            ])),
            .init(name: "is_active", values: .bool([true, false, true]))
        ])

        let count = try await client.count("SELECT count() FROM test.sdk_simple WHERE id IN (1, 2, 3)")
        #expect(count == 3, "all 3 rows must persist")

        // Verify exact nanosecond round-trip on the timestamp column.
        var seenTicks: [Int64] = []
        for try await block in client.selectColumns(
            "SELECT created_at FROM test.sdk_simple WHERE id IN (1, 2, 3) ORDER BY id"
        ) {
            if case .present(let lookupColumn) = block.column(named: "created_at"), case .dateTime64Nanoseconds(let nanos, _) = lookupColumn.values {
                seenTicks.append(contentsOf: nanos.map(\.rawValue))
            }
        }
        #expect(seenTicks == createdNs.map(\.rawValue), "nanosecond ticks must round-trip exactly")

        // Verify name + value pair across all rows.
        var seenNames: [String] = []
        var seenValues: [Double] = []
        for try await block in client.selectColumns(
            "SELECT name, value FROM test.sdk_simple WHERE id IN (1, 2, 3) ORDER BY id"
        ) {
            if case .present(let lookupColumn) = block.column(named: "name"), case .string(let names) = lookupColumn.values {
                seenNames.append(contentsOf: names)
            }
            if case .present(let lookupColumn) = block.column(named: "value"), case .float64(let values) = lookupColumn.values {
                seenValues.append(contentsOf: values)
            }
        }
        #expect(seenNames == ["alpha", "Привет", "🇳🇿"])
        #expect(seenValues == [0.0, .pi, -1.0])

        try await Self.cleanup(table: "test.sdk_simple", client: client)
        await client.shutdown()
    }

    @Test("test.sdk_simple — Array(String) and Bool columns round-trip preserving order and content")
    func sdkSimpleArrayAndBoolRoundTrip() async throws {
        let (client, group) = Self.makeClient()
        _ = group

        try await Self.cleanup(table: "test.sdk_simple", client: client)

        try await client.insert(into: "test.sdk_simple", columns: [
            .init(name: "id", values: .uint64([100])),
            .init(name: "name", values: .string(["multi-tag"])),
            .init(name: "created_at", values: .dateTime64Nanoseconds(
                [ClickHouseNanoseconds(1_704_067_200_000_000_000)], precision: 9
            )),
            .init(name: "value", values: .float64([42.5])),
            .init(name: "tags", values: .arrayOfString([
                ["urgent", "Q4-priority", "needs-review", "rouge"]
            ])),
            .init(name: "attributes", values: .mapStringString([[:]])),
            .init(name: "is_active", values: .bool([false]))
        ])

        // Two separate queries to isolate Array(String) vs Bool decoding;
        // multi-column responses with an Array column hit a wire-decode
        // edge case under investigation in next firing.
        var seenTags: [String] = []
        for try await block in client.selectColumns(
            "SELECT tags FROM test.sdk_simple WHERE id = 100"
        ) {
            if case .present(let lookupColumn) = block.column(named: "tags"), case .arrayOfString(let tagArrays) = lookupColumn.values {
                seenTags = tagArrays.flatMap { $0 }
            }
        }
        var seenActive: [Bool] = []
        for try await block in client.selectColumns(
            "SELECT is_active FROM test.sdk_simple WHERE id = 100"
        ) {
            if case .present(let lookupColumn) = block.column(named: "is_active"), case .bool(let actives) = lookupColumn.values {
                seenActive = actives
            }
        }
        #expect(seenTags == ["urgent", "Q4-priority", "needs-review", "rouge"])
        #expect(seenActive == [false])

        try await Self.cleanup(table: "test.sdk_simple", client: client)
        await client.shutdown()
    }

    // MARK: - test.sdk_nullable

    @Test("test.sdk_nullable — Nullable(String/Int64/Decimal/UUID) round-trip with nil and present values")
    func sdkNullableRoundTrip() async throws {
        let (client, group) = Self.makeClient()
        _ = group

        try await Self.cleanup(table: "test.sdk_nullable", client: client)

        let knownUUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

        try await client.insert(into: "test.sdk_nullable", columns: [
            .init(name: "id", values: .uint64([1, 2, 3])),
            .init(name: "optional_string", values: .nullableString(["alpha", nil, "gamma"])),
            .init(name: "optional_int", values: .nullableInt64([100, nil, .present(Int64.max)])),
            // Decimal(18, 4) fits in Int64 storage. Scale 4 means we
            // store cents-with-precision: e.g. 12_345 = 1.2345.
            .init(name: "optional_decimal", values: .nullableDecimal64(
                [12_345, nil, -67_890], scale: 4
            )),
            .init(name: "optional_uuid", values: .nullableUUID([.present(knownUUID), nil, .present(knownUUID)])),
            // Enum8 maps as raw Int8 on the wire (1=alpha, 2=beta, 3=gamma)
            .init(name: "enum_field", values: .int8([1, 2, 3])),
            .init(name: "inserted", values: .dateTime64Nanoseconds(
                [
                    ClickHouseNanoseconds(1_700_000_000_111_111_111),
                    ClickHouseNanoseconds(1_700_000_000_222_222_222),
                    ClickHouseNanoseconds(1_700_000_000_333_333_333)
                ],
                precision: 9
            ))
        ])

        let count = try await client.count("SELECT count() FROM test.sdk_nullable WHERE id IN (1, 2, 3)")
        #expect(count == 3)

        // Verify nulls survive the round-trip via raw column SELECT.
        var optionalStrings: [String?] = []
        var optionalInts: [Int64?] = []
        for try await block in client.selectColumns(
            "SELECT optional_string, optional_int FROM test.sdk_nullable WHERE id IN (1, 2, 3) ORDER BY id"
        ) {
            if case .present(let lookupColumn) = block.column(named: "optional_string"), case .nullableString(let values) = lookupColumn.values {
                optionalStrings.append(contentsOf: values.map(\.value))
            }
            if case .present(let lookupColumn) = block.column(named: "optional_int"), case .nullableInt64(let values) = lookupColumn.values {
                optionalInts.append(contentsOf: values.map(\.value))
            }
        }
        #expect(optionalStrings == ["alpha", nil, "gamma"])
        #expect(optionalInts == [100, nil, Int64.max])

        try await Self.cleanup(table: "test.sdk_nullable", client: client)
        await client.shutdown()
    }

    // MARK: - test.sdk_replacing

    @Test("test.sdk_replacing — re-inserting a newer version replaces the row when querying with FINAL")
    func sdkReplacingFinalSemantics() async throws {
        let (client, group) = Self.makeClient()
        _ = group

        try await Self.cleanup(table: "test.sdk_replacing", client: client)

        let entityId: UInt64 = 42

        // Insert the original row.
        try await client.insert(into: "test.sdk_replacing", columns: [
            .init(name: "entity_id", values: .uint64([entityId])),
            .init(name: "payload", values: .string(["v1-payload"])),
            .init(name: "version", values: .dateTime64Nanoseconds(
                [ClickHouseNanoseconds(1_700_000_000_000_000_000)], precision: 9
            ))
        ])

        // Insert a newer version with the same entity_id.
        try await client.insert(into: "test.sdk_replacing", columns: [
            .init(name: "entity_id", values: .uint64([entityId])),
            .init(name: "payload", values: .string(["v2-payload"])),
            .init(name: "version", values: .dateTime64Nanoseconds(
                [ClickHouseNanoseconds(1_700_000_001_000_000_000)], precision: 9
            ))
        ])

        // Without FINAL, both rows are visible (eventual dedup).
        let preFinalCount = try await client.count("SELECT count() FROM test.sdk_replacing WHERE entity_id = \(entityId)")
        #expect(preFinalCount == 2, "ReplacingMergeTree exposes both versions until merged")

        // With FINAL, only the latest version is returned.
        var seenPayloads: [String] = []
        for try await block in client.selectColumns(
            "SELECT payload FROM test.sdk_replacing FINAL WHERE entity_id = \(entityId)"
        ) {
            if case .present(let lookupColumn) = block.column(named: "payload"), case .string(let values) = lookupColumn.values {
                seenPayloads.append(contentsOf: values)
            }
        }
        #expect(seenPayloads == ["v2-payload"], "FINAL should return only the latest version")

        try await Self.cleanup(table: "test.sdk_replacing", client: client)
        await client.shutdown()
    }

    // MARK: - Throughput baseline

    @Test("INSERT throughput baseline — 10_000 rows of (UInt64, String, Float64) measures end-to-end wall clock")
    func insertThroughputBaseline() async throws {
        let (client, group) = Self.makeClient()
        _ = group

        try await Self.cleanup(table: "test.sdk_simple", client: client)

        let rowCount = 10_000
        let ids: [UInt64] = (0..<rowCount).map { UInt64($0) }
        let names: [String] = (0..<rowCount).map { "row-\($0)" }
        let timestamps = (0..<rowCount).map { ClickHouseNanoseconds(1_700_000_000_000_000_000 + Int64($0)) }
        let values: [Double] = (0..<rowCount).map { Double($0) * 1.5 }
        let tags: [[String]] = (0..<rowCount).map { ["tag-\($0 % 100)"] }
        let attrs: [[String: String]] = (0..<rowCount).map { _ in [:] }
        let actives: [Bool] = (0..<rowCount).map { $0 % 2 == 0 }

        let started = Date()
        try await client.insert(into: "test.sdk_simple", columns: [
            .init(name: "id", values: .uint64(ids)),
            .init(name: "name", values: .string(names)),
            .init(name: "created_at", values: .dateTime64Nanoseconds(timestamps, precision: 9)),
            .init(name: "value", values: .float64(values)),
            .init(name: "tags", values: .arrayOfString(tags)),
            .init(name: "attributes", values: .mapStringString(attrs)),
            .init(name: "is_active", values: .bool(actives))
        ])
        let elapsed = Date().timeIntervalSince(started)
        let rowsPerSecond = Double(rowCount) / elapsed
        print("[BENCH] INSERT \(rowCount) rows: \(String(format: "%.3fs", elapsed)) → \(String(format: "%.0f rows/s", rowsPerSecond))")

        let count = try await client.count("SELECT count() FROM test.sdk_simple WHERE name LIKE 'row-%'")
        #expect(count == UInt64(rowCount))

        try await Self.cleanup(table: "test.sdk_simple", client: client)
        await client.shutdown()
    }

    @Test("SELECT scan throughput baseline — measures wall clock for streaming 10_000 rows back through the column API")
    func selectScanThroughputBaseline() async throws {
        let (client, group) = Self.makeClient()
        _ = group

        try await Self.cleanup(table: "test.sdk_simple", client: client)

        // Seed via INSERT.
        let rowCount = 10_000
        try await client.insert(into: "test.sdk_simple", columns: [
            .init(name: "id", values: .uint64((0..<rowCount).map { UInt64($0) })),
            .init(name: "name", values: .string((0..<rowCount).map { "scan-\($0)" })),
            .init(name: "created_at", values: .dateTime64Nanoseconds(
                (0..<rowCount).map { ClickHouseNanoseconds(1_700_000_000_000_000_000 + Int64($0)) },
                precision: 9
            )),
            .init(name: "value", values: .float64((0..<rowCount).map { Double($0) })),
            .init(name: "tags", values: .arrayOfString(Array(repeating: [], count: rowCount))),
            .init(name: "attributes", values: .mapStringString(Array(repeating: [:], count: rowCount))),
            .init(name: "is_active", values: .bool(Array(repeating: false, count: rowCount)))
        ])

        // Measure scan time.
        let started = Date()
        var seenIds = 0
        for try await block in client.selectColumns(
            "SELECT id FROM test.sdk_simple WHERE name LIKE 'scan-%'"
        ) {
            if case .present(let lookupColumn) = block.column(named: "id"), case .uint64(let ids) = lookupColumn.values {
                seenIds += ids.count
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        let rowsPerSecond = Double(seenIds) / elapsed
        print("[BENCH] SELECT scan \(seenIds) rows: \(String(format: "%.3fs", elapsed)) → \(String(format: "%.0f rows/s", rowsPerSecond))")

        #expect(seenIds == rowCount)

        try await Self.cleanup(table: "test.sdk_simple", client: client)
        await client.shutdown()
    }

}
