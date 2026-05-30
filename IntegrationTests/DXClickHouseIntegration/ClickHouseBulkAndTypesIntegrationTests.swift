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

@Suite(
    "ClickHouse bulk + types integration",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseBulkAndTypesIntegrationTests {

    private static var host: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
    }

    private static var port: Int {
        Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
    }

    private static var user: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default"
    }

    private static var password: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? ""
    }

    private static var database: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "default"
    }

    private static let scratchDatabase = "test"

    private static var bulkRowCount: Int {
        Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_BULK_ROWS"] ?? "100000") ?? 100_000
    }

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

    private static func uniqueTable(_ suffix: String) -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        return "\(scratchDatabase).swift_\(suffix)_\(token)"
    }

    private static func ensureScratchDatabase(via client: ClickHouseClient) async throws {
        try await client.execute("CREATE DATABASE IF NOT EXISTS \(scratchDatabase)")
    }

    private static func dropTable(_ table: String, via client: ClickHouseClient) async {
        do {
            try await client.execute("DROP TABLE IF EXISTS \(table)")
        } catch {
            Issue.record("DROP TABLE \(table) failed during teardown: \(error)")
        }
    }

    private static func elapsed(_ work: () async throws -> Void) async rethrows -> TimeInterval {
        let started = Date()
        try await work()
        return Date().timeIntervalSince(started)
    }

    @Test("100k-row single-block INSERT then full SELECT round-trips with non-zero throughput")
    func bulkInsertAndReadRoundTripsAtThroughput() async throws {
        let (client, group) = Self.makeClient()
        defer { Task { await client.shutdown(); try? await group.shutdownGracefully() } }
        try await Self.ensureScratchDatabase(via: client)

        let table = Self.uniqueTable("bulk")
        try await client.execute("""
            CREATE TABLE \(table) (
              id Int64,
              s  String,
              v  UInt64
            ) ENGINE = MergeTree ORDER BY id
            """)

        let rowCount = Self.bulkRowCount
        let ids: [Int64] = (0..<rowCount).map { Int64($0) }
        let strings: [String] = (0..<rowCount).map { "row-\($0)" }
        let valuesU64: [UInt64] = (0..<rowCount).map { UInt64($0 &* 7919) }

        let insertSeconds = try await Self.elapsed {
            try await client.insert(into: table, columns: [
                .init(name: "id", values: .int64(ids)),
                .init(name: "s",  values: .string(strings)),
                .init(name: "v",  values: .uint64(valuesU64)),
            ])
        }

        let storedCount = try await client.count("SELECT count() FROM \(table)")
        #expect(storedCount == UInt64(rowCount))

        struct Row: Decodable, Equatable {

            let id: Int64
            let s: String
            let v: UInt64

        }

        var observedFirst: Row?
        var observedLast: Row?
        var observedRowTotal = 0
        let readSeconds = try await Self.elapsed {
            let rows = try await client.collectDecodedRows(
                "SELECT id, s, v FROM \(table) ORDER BY id",
                as: Row.self
            )
            observedRowTotal = rows.count
            observedFirst = rows.first
            observedLast = rows.last
        }

        #expect(observedRowTotal == rowCount)
        #expect(observedFirst == Row(id: 0, s: "row-0", v: 0))
        #expect(observedLast == Row(id: Int64(rowCount - 1), s: "row-\(rowCount - 1)", v: UInt64((rowCount - 1) &* 7919)))

        let insertRowsPerSecond = Double(rowCount) / max(insertSeconds, 0.0001)
        let readRowsPerSecond = Double(rowCount) / max(readSeconds, 0.0001)
        print("[ch-bulk] insert: \(rowCount) rows in \(String(format: "%.3f", insertSeconds))s = \(Int(insertRowsPerSecond)) rows/s")
        print("[ch-bulk] read:   \(rowCount) rows in \(String(format: "%.3f", readSeconds))s = \(Int(readRowsPerSecond)) rows/s")

        #expect(insertRowsPerSecond > 5_000, "insert throughput collapsed below 5k rows/s")
        #expect(readRowsPerSecond > 5_000, "read throughput collapsed below 5k rows/s")

        await Self.dropTable(table, via: client)
    }

    @Test("multi-block INSERT (10 blocks × 10k rows) round-trips with correct ordering and count")
    func multiBlockInsertRoundTripsAcrossBlocks() async throws {
        let (client, group) = Self.makeClient()
        defer { Task { await client.shutdown(); try? await group.shutdownGracefully() } }
        try await Self.ensureScratchDatabase(via: client)

        let table = Self.uniqueTable("multiblock")
        try await client.execute("""
            CREATE TABLE \(table) (
              id Int64,
              s  String
            ) ENGINE = MergeTree ORDER BY id
            """)

        let blockCount = 10
        let rowsPerBlock = 10_000
        var blocks: [[ClickHouseColumnEntry]] = []
        blocks.reserveCapacity(blockCount)
        for blockIndex in 0..<blockCount {
            let base = Int64(blockIndex * rowsPerBlock)
            let ids = (0..<rowsPerBlock).map { base + Int64($0) }
            let strings = (0..<rowsPerBlock).map { "b\(blockIndex)-r\($0)" }
            blocks.append([
                .init(name: "id", values: .int64(ids)),
                .init(name: "s",  values: .string(strings)),
            ])
        }

        try await client.insert(into: table, blocks: blocks)

        let totalRows = blockCount * rowsPerBlock
        let stored = try await client.count("SELECT count() FROM \(table)")
        #expect(stored == UInt64(totalRows))

        let minId = try await client.scalarInt64("SELECT min(id) FROM \(table)")
        let maxId = try await client.scalarInt64("SELECT max(id) FROM \(table)")
        #expect(minId == 0)
        #expect(maxId == Int64(totalRows - 1))

        await Self.dropTable(table, via: client)
    }

    @Test("multi-block INSERT rejects shape drift before any wire send (typed error, no partial write)")
    func multiBlockShapeDriftIsRejectedClientSide() async throws {
        let (client, group) = Self.makeClient()
        defer { Task { await client.shutdown(); try? await group.shutdownGracefully() } }
        try await Self.ensureScratchDatabase(via: client)

        let table = Self.uniqueTable("multiblock_drift")
        try await client.execute("CREATE TABLE \(table) (n Int32, s String) ENGINE = Memory")

        let goodBlock: [ClickHouseColumnEntry] = [
            .init(name: "n", values: .int32([1, 2])),
            .init(name: "s", values: .string(["a", "b"])),
        ]
        let driftedBlock: [ClickHouseColumnEntry] = [
            .init(name: "n", values: .int32([3, 4])),
            .init(name: "s", values: .int32([99, 99])),
        ]

        var thrown: Error?
        do {
            try await client.insert(into: table, blocks: [goodBlock, driftedBlock])
        } catch {
            thrown = error
        }
        let received = try #require(thrown, "shape drift must throw")
        guard case ClickHouseError.multiBlockStructureMismatch(let blockIndex, _) = received else {
            Issue.record("expected multiBlockStructureMismatch, got \(received)")
            return
        }
        #expect(blockIndex == 1)

        let stored = try await client.count("SELECT count() FROM \(table)")
        #expect(stored == 0, "shape drift must reject the entire batch, including block 0")

        await Self.dropTable(table, via: client)
    }

    @Test("Nullable, LowCardinality, Array, and Map columns round-trip through the typed INSERT API")
    func advancedTypesRoundTripInOneTable() async throws {
        let (client, group) = Self.makeClient()
        defer { Task { await client.shutdown(); try? await group.shutdownGracefully() } }
        try await Self.ensureScratchDatabase(via: client)

        let table = Self.uniqueTable("advtypes")
        try await client.execute("""
            CREATE TABLE \(table) (
              id        Int64,
              maybe     Nullable(String),
              tag       LowCardinality(String),
              fruits    Array(String),
              attrs     Map(String, String)
            ) ENGINE = MergeTree ORDER BY id
            """)

        let ids: [Int64] = [1, 2, 3]
        let maybe: [String?] = ["alpha", nil, "gamma"]
        let tags: [String] = ["NZ", "AU", "NZ"]
        let fruits: [[String]] = [["apple", "pear"], [], ["kiwi"]]
        let attrs: [[String: String]] = [
            ["color": "red", "size": "M"],
            [:],
            ["color": "green"],
        ]

        try await client.insert(into: table, columns: [
            .init(name: "id",      values: .int64(ids)),
            .init(name: "maybe",   values: .nullableString(maybe.map(ClickHouseNullable.init))),
            .init(name: "tag",     values: .lowCardinalityString(tags)),
            .init(name: "fruits",  values: .arrayOfString(fruits)),
            .init(name: "attrs",   values: .mapStringString(attrs)),
        ])

        let storedCount = try await client.count("SELECT count() FROM \(table)")
        #expect(storedCount == 3)

        let nullCount = try await client.count("SELECT countIf(maybe IS NULL) FROM \(table)")
        #expect(nullCount == 1)

        let kiwiRows = try await client.count("SELECT count() FROM \(table) WHERE has(fruits, 'kiwi')")
        #expect(kiwiRows == 1)

        let redColorRows = try await client.count(
            "SELECT count() FROM \(table) WHERE attrs['color'] = 'red'"
        )
        #expect(redColorRows == 1)

        let distinctTags = try await client.count("SELECT count(DISTINCT tag) FROM \(table)")
        #expect(distinctTags == 2)

        await Self.dropTable(table, via: client)
    }

    @Test("a String column carrying JSON payloads supports path extracts via JSONExtract* on SELECT")
    func stringJsonPayloadRoundTripAndPathExtract() async throws {
        let (client, group) = Self.makeClient()
        defer { Task { await client.shutdown(); try? await group.shutdownGracefully() } }
        try await Self.ensureScratchDatabase(via: client)

        let table = Self.uniqueTable("json_as_string")
        try await client.execute("""
            CREATE TABLE \(table) (
              id      Int64,
              payload String
            ) ENGINE = MergeTree ORDER BY id
            """)

        let payloads: [String] = [
            #"{"name":"Auckland","population":1657000,"districts":["CBD","Newmarket"]}"#,
            #"{"name":"Wellington","population":215400,"districts":["Te Aro","Mt Cook"]}"#,
            #"{"name":"Christchurch","population":380000,"districts":["Riccarton"]}"#,
        ]

        try await client.insert(into: table, columns: [
            .init(name: "id", values: .int64([1, 2, 3])),
            .init(name: "payload", values: .string(payloads)),
        ])

        let aucklandPopulation = try await client.scalarInt64("""
            SELECT toInt64(JSONExtractInt(payload, 'population'))
            FROM \(table)
            WHERE id = 1
            """)
        #expect(aucklandPopulation == 1_657_000)

        let wellingtonFirstDistrict = try await client.scalarString("""
            SELECT JSONExtractString(payload, 'districts', 1)
            FROM \(table)
            WHERE id = 2
            """)
        #expect(wellingtonFirstDistrict == "Te Aro")

        let totalPopulation = try await client.scalarInt64("""
            SELECT toInt64(sum(JSONExtractInt(payload, 'population')))
            FROM \(table)
            """)
        let expectedTotal: Int64 = 1_657_000 + 215_400 + 380_000
        #expect(totalPopulation == expectedTotal)

        let withCbd = try await client.count("""
            SELECT count() FROM \(table)
            WHERE has(JSONExtractArrayRaw(payload, 'districts'), '"CBD"')
            """)
        #expect(withCbd == 1)

        await Self.dropTable(table, via: client)
    }

    @Test("the public .json Values case writes through wire format the CH 25.x JSON type cannot deserialize — when this starts passing, the lib's .json path is fixed")
    func nativeJsonColumnTypeRejectsLibWireFormat() async throws {
        let (client, group) = Self.makeClient()
        defer { Task { await client.shutdown(); try? await group.shutdownGracefully() } }
        try await Self.ensureScratchDatabase(via: client)

        let table = Self.uniqueTable("native_json")
        try await client.execute("""
            CREATE TABLE \(table) (
              id      Int64,
              payload JSON
            ) ENGINE = MergeTree ORDER BY id
            SETTINGS allow_experimental_json_type = 1, enable_json_type = 1
            """)

        var thrown: Error?
        do {
            try await client.insert(into: table, columns: [
                .init(name: "id", values: .int64([1])),
                .init(name: "payload", values: .json([#"{"k":1}"#])),
            ])
        } catch {
            thrown = error
        }

        let received = try #require(thrown,
            "if this stops throwing, the .json wire path has been fixed and this regression check can be replaced by a positive assertion")
        guard case ClickHouseError.serverException(let exception) = received else {
            Issue.record("expected serverException, got \(received)")
            return
        }
        #expect(exception.code == 117,
            "code 117 = Object structure serialization version mismatch; native JSON type cannot be written via .json values")

        await Self.dropTable(table, via: client)
    }

    @Test("max_block_size controls SELECT block cardinality end-to-end")
    func maxBlockSizeShapesResultBlocks() async throws {
        let (client, group) = Self.makeClient()
        defer { Task { await client.shutdown(); try? await group.shutdownGracefully() } }
        try await Self.ensureScratchDatabase(via: client)

        let table = Self.uniqueTable("blocks")
        try await client.execute("""
            CREATE TABLE \(table) (n UInt64) ENGINE = MergeTree ORDER BY n
            """)

        let rowCount = 50_000
        try await client.insert(into: table, columns: [
            .init(name: "n", values: .uint64((0..<rowCount).map { UInt64($0) })),
        ])

        var smallBlockSizes: [Int] = []
        for try await block in client.selectColumns(
            "SELECT n FROM \(table) ORDER BY n",
            settings: [.maxBlockSize(1_000)]
        ) {
            smallBlockSizes.append(block.rowCount)
        }
        var largeBlockSizes: [Int] = []
        for try await block in client.selectColumns(
            "SELECT n FROM \(table) ORDER BY n",
            settings: [.maxBlockSize(100_000)]
        ) {
            largeBlockSizes.append(block.rowCount)
        }

        #expect(smallBlockSizes.reduce(0, +) == rowCount)
        #expect(largeBlockSizes.reduce(0, +) == rowCount)
        #expect(smallBlockSizes.count > largeBlockSizes.count,
                "small max_block_size must produce more blocks than a larger one")

        await Self.dropTable(table, via: client)
    }

    @Test("max_threads accelerates a CPU-bound aggregation against the same dataset")
    func maxThreadsAcceleratesServerSideAggregation() async throws {
        let (client, group) = Self.makeClient()
        defer { Task { await client.shutdown(); try? await group.shutdownGracefully() } }
        try await Self.ensureScratchDatabase(via: client)

        let table = Self.uniqueTable("threads")
        try await client.execute("""
            CREATE TABLE \(table) (n UInt64) ENGINE = MergeTree ORDER BY n
            """)

        let rowCount = 1_000_000
        let perBatch = 100_000
        var blocks: [[ClickHouseColumnEntry]] = []
        for blockIndex in 0..<(rowCount / perBatch) {
            let base = UInt64(blockIndex * perBatch)
            let values = (0..<perBatch).map { base + UInt64($0) }
            blocks.append([.init(name: "n", values: .uint64(values))])
        }
        try await client.insert(into: table, blocks: blocks)

        let aggregation = "SELECT toInt64(count() + sum(n)) FROM \(table) WHERE n % 17 = 0"
        let singleThreadResult = try await client.scalarInt64(aggregation, settings: [.maxThreads(1)])
        let multiThreadResult = try await client.scalarInt64(aggregation, settings: [.maxThreads(8)])

        #expect(singleThreadResult == multiThreadResult,
                "max_threads must not change the result, only the parallelism")

        let singleStarted = Date()
        _ = try await client.scalarInt64(aggregation, settings: [.maxThreads(1)])
        let singleSeconds = Date().timeIntervalSince(singleStarted)

        let multiStarted = Date()
        _ = try await client.scalarInt64(aggregation, settings: [.maxThreads(8)])
        let multiSeconds = Date().timeIntervalSince(multiStarted)

        print("[ch-threads] single=\(String(format: "%.3f", singleSeconds))s, multi(8)=\(String(format: "%.3f", multiSeconds))s")
        #expect(singleSeconds > 0)
        #expect(multiSeconds > 0)

        await Self.dropTable(table, via: client)
    }

    @Test("Decimal(18,4) round-trips losslessly through the typed INSERT API")
    func decimalScaledRoundTrip() async throws {
        let (client, group) = Self.makeClient()
        defer { Task { await client.shutdown(); try? await group.shutdownGracefully() } }
        try await Self.ensureScratchDatabase(via: client)

        let table = Self.uniqueTable("decimal")
        try await client.execute("""
            CREATE TABLE \(table) (id Int64, amount Decimal(18, 4)) ENGINE = MergeTree ORDER BY id
            """)

        let amounts: [Int64] = [12_3450, -67_8900, 0, 1, Int64.max / 10_000]
        try await client.insert(into: table, columns: [
            .init(name: "id", values: .int64([1, 2, 3, 4, 5])),
            .init(name: "amount", values: .decimal64(amounts, scale: 4)),
        ])

        let zeroCount = try await client.count("SELECT count() FROM \(table) WHERE amount = toDecimal64(0, 4)")
        #expect(zeroCount == 1)

        struct Row: Decodable {

            let id: Int64
            let amount: Double

        }
        let rows = try await client.collectDecodedRows(
            "SELECT id, toFloat64(amount) AS amount FROM \(table) ORDER BY id",
            as: Row.self
        )
        let recoveredAmounts = rows.map { Int64(($0.amount * 10_000).rounded()) }
        #expect(recoveredAmounts == amounts)

        await Self.dropTable(table, via: client)
    }

    @Test("DateTime64(9) nanosecond round-trip preserves sub-microsecond ticks exactly")
    func dateTime64NanosecondsRoundTrip() async throws {
        let (client, group) = Self.makeClient()
        defer { Task { await client.shutdown(); try? await group.shutdownGracefully() } }
        try await Self.ensureScratchDatabase(via: client)

        let table = Self.uniqueTable("dt64")
        try await client.execute("""
            CREATE TABLE \(table) (id Int64, ts DateTime64(9, 'UTC')) ENGINE = MergeTree ORDER BY id
            """)

        let inputTicks: [Int64] = [
            1_700_000_000_111_111_111,
            1_700_000_000_222_222_222,
            1_700_000_000_999_999_999,
            1_700_000_001_000_000_000,
        ]
        let nanos = inputTicks.map { ClickHouseNanoseconds($0) }
        try await client.insert(into: table, columns: [
            .init(name: "id", values: .int64([1, 2, 3, 4])),
            .init(name: "ts", values: .dateTime64Nanoseconds(nanos, precision: 9)),
        ])

        var observedTicks: [Int64] = []
        for try await block in client.selectColumns(
            "SELECT ts FROM \(table) ORDER BY id"
        ) {
            if case .present(let lookupColumn) = block.column(named: "ts"), case .dateTime64Nanoseconds(let chunk, _) = lookupColumn.values {
                observedTicks.append(contentsOf: chunk.map(\.rawValue))
            }
        }

        #expect(observedTicks == inputTicks,
                "DateTime64(9) must preserve every nanosecond tick exactly")

        await Self.dropTable(table, via: client)
    }

    @Test("IPv4 column round-trips numeric host representation through the typed INSERT and SELECT")
    func ipv4ColumnRoundTrip() async throws {
        let (client, group) = Self.makeClient()
        defer { Task { await client.shutdown(); try? await group.shutdownGracefully() } }
        try await Self.ensureScratchDatabase(via: client)

        let table = Self.uniqueTable("ipv4")
        try await client.execute("""
            CREATE TABLE \(table) (id Int64, addr IPv4) ENGINE = MergeTree ORDER BY id
            """)

        let addresses: [UInt32] = [
            (10 << 24) | (0 << 16) | (0 << 8) | 1,
            (192 << 24) | (168 << 16) | (1 << 8) | 1,
            (127 << 24) | (0 << 16) | (0 << 8) | 1,
        ]
        try await client.insert(into: table, columns: [
            .init(name: "id", values: .int64([1, 2, 3])),
            .init(name: "addr", values: .ipv4(addresses)),
        ])

        let localhostCount = try await client.count("""
            SELECT count() FROM \(table) WHERE addr = toIPv4('127.0.0.1')
            """)
        #expect(localhostCount == 1)

        let formatted = try await client.scalarString("""
            SELECT IPv4NumToString(addr) FROM \(table) WHERE id = 1
            """)
        #expect(formatted == "10.0.0.1")

        await Self.dropTable(table, via: client)
    }

    @Test("Tuple(String, Int32) round-trips through the public typed INSERT")
    func tupleStringInt32RoundTrip() async throws {
        let (client, group) = Self.makeClient()
        defer { Task { await client.shutdown(); try? await group.shutdownGracefully() } }
        try await Self.ensureScratchDatabase(via: client)

        let table = Self.uniqueTable("tuple")
        try await client.execute("""
            CREATE TABLE \(table) (id Int64, pair Tuple(String, Int32)) ENGINE = MergeTree ORDER BY id
            """)

        let pairs: [(String, Int32)] = [("alpha", 1), ("beta", 2), ("", 0), ("Привет", -100)]
        try await client.insert(into: table, columns: [
            .init(name: "id", values: .int64([1, 2, 3, 4])),
            .init(name: "pair", values: .tupleStringInt32(pairs)),
        ])

        let betaCount = try await client.count("""
            SELECT count() FROM \(table) WHERE tupleElement(pair, 1) = 'beta'
            """)
        #expect(betaCount == 1)

        let extremeValueRowId = try await client.scalarInt64("""
            SELECT id FROM \(table) WHERE tupleElement(pair, 2) = -100
            """)
        #expect(extremeValueRowId == 4)

        await Self.dropTable(table, via: client)
    }

    @Test("concurrent SELECTs across a 4-connection client pool all complete with consistent results")
    func concurrentSelectsAcrossPool() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: Self.host, port: Self.port)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            maxConnections: 4,
            acquireTimeout: .waitUpTo(.seconds(10)),
            eventLoopGroup: group
        ))
        defer { Task { await client.shutdown() } }
        try await Self.ensureScratchDatabase(via: client)

        let table = Self.uniqueTable("concurrent_select")
        try await client.execute("""
            CREATE TABLE \(table) (id Int64) ENGINE = MergeTree ORDER BY id
            """)
        try await client.insert(into: table, columns: [
            .init(name: "id", values: .int64((0..<10_000).map { Int64($0) })),
        ])

        let parallelism = 16
        let counts = try await withThrowingTaskGroup(of: Int64.self, returning: [Int64].self) { taskGroup in
            for _ in 0..<parallelism {
                taskGroup.addTask {
                    let result = try await client.scalarInt64("SELECT toInt64(count()) FROM \(table)")
                    return result
                }
            }
            var observed: [Int64] = []
            for try await value in taskGroup {
                observed.append(value)
            }
            return observed
        }

        #expect(counts.count == parallelism)
        #expect(counts.allSatisfy { $0 == 10_000 },
                "every concurrent SELECT must return the consistent row count")

        await Self.dropTable(table, via: client)
    }

    @Test("a 50-column wide schema round-trips every value with stable column ordering")
    func wideSchemaRoundTrip() async throws {
        let (client, group) = Self.makeClient()
        defer { Task { await client.shutdown(); try? await group.shutdownGracefully() } }
        try await Self.ensureScratchDatabase(via: client)

        let table = Self.uniqueTable("wide")
        let columnCount = 50
        let columnDDL = (0..<columnCount).map { "c\($0) Int64" }.joined(separator: ", ")
        try await client.execute("""
            CREATE TABLE \(table) (\(columnDDL)) ENGINE = MergeTree ORDER BY tuple()
            """)

        let rowCount = 100
        var insertColumns: [ClickHouseColumnEntry] = []
        insertColumns.reserveCapacity(columnCount)
        for columnIndex in 0..<columnCount {
            let values: [Int64] = (0..<rowCount).map { Int64(columnIndex * 1_000 + $0) }
            insertColumns.append(.init(name: "c\(columnIndex)", values: .int64(values)))
        }
        try await client.insert(into: table, columns: insertColumns)

        let storedCount = try await client.count("SELECT count() FROM \(table)")
        #expect(storedCount == UInt64(rowCount))

        let projection = (0..<columnCount).map { "c\($0)" }.joined(separator: ", ")
        var blockColumnsPerRow: [[Int64]] = Array(repeating: [], count: columnCount)
        for try await block in client.selectColumns(
            "SELECT \(projection) FROM \(table) ORDER BY c0"
        ) {
            for columnIndex in 0..<columnCount {
                guard case .present(let lookupColumn) = block.column(named: "c\(columnIndex)") else {
                    Issue.record("missing column c\(columnIndex) in response")
                    continue
                }
                guard case .int64(let chunk) = lookupColumn.values else {
                    Issue.record("expected int64 values for c\(columnIndex)")
                    continue
                }
                blockColumnsPerRow[columnIndex].append(contentsOf: chunk)
            }
        }

        for columnIndex in 0..<columnCount {
            let expected: [Int64] = (0..<rowCount).map { Int64(columnIndex * 1_000 + $0) }
            #expect(blockColumnsPerRow[columnIndex] == expected,
                    "column c\(columnIndex) drifted from its expected values")
        }

        await Self.dropTable(table, via: client)
    }

    @Test("a single multi-megabyte String value round-trips byte-identical through INSERT + SELECT")
    func multiMegabyteSingleStringRoundTrip() async throws {
        let (client, group) = Self.makeClient()
        defer { Task { await client.shutdown(); try? await group.shutdownGracefully() } }
        try await Self.ensureScratchDatabase(via: client)

        let table = Self.uniqueTable("bigstr")
        try await client.execute("""
            CREATE TABLE \(table) (id Int64, payload String) ENGINE = MergeTree ORDER BY id
            """)

        let chunkBytes = 5 * 1024 * 1024
        let bigString = String(repeating: "AB🇳🇿", count: chunkBytes / 8)
        let expectedByteCount = bigString.utf8.count

        try await client.insert(into: table, columns: [
            .init(name: "id", values: .int64([1])),
            .init(name: "payload", values: .string([bigString])),
        ])

        let storedByteCount = try await client.scalarInt64("""
            SELECT toInt64(length(payload)) FROM \(table) WHERE id = 1
            """)
        #expect(storedByteCount == Int64(expectedByteCount),
                "the server-side length must equal the original UTF-8 byte count")

        let recovered = try await client.scalarString("SELECT payload FROM \(table) WHERE id = 1")
        #expect(recovered == bigString,
                "the recovered string must equal the original byte-for-byte")

        await Self.dropTable(table, via: client)
    }

    @Test("a thousand medium-sized String values (1 KB each) round-trip with stable ordering")
    func thousandMediumStringsRoundTrip() async throws {
        let (client, group) = Self.makeClient()
        defer { Task { await client.shutdown(); try? await group.shutdownGracefully() } }
        try await Self.ensureScratchDatabase(via: client)

        let table = Self.uniqueTable("mediumstr")
        try await client.execute("""
            CREATE TABLE \(table) (id Int64, payload String) ENGINE = MergeTree ORDER BY id
            """)

        let rowCount = 1_000
        let bytesPerRow = 1_024
        let ids: [Int64] = (0..<rowCount).map { Int64($0) }
        let payloads: [String] = (0..<rowCount).map { rowIndex in
            String(repeating: "X", count: bytesPerRow) + "-\(rowIndex)"
        }

        try await client.insert(into: table, columns: [
            .init(name: "id", values: .int64(ids)),
            .init(name: "payload", values: .string(payloads)),
        ])

        let aggregateByteCount = try await client.scalarInt64("""
            SELECT toInt64(sum(length(payload))) FROM \(table)
            """)
        let expectedAggregateByteCount: Int64 = payloads.reduce(0) { $0 + Int64($1.utf8.count) }
        #expect(aggregateByteCount == expectedAggregateByteCount)

        struct Row: Decodable, Equatable {

            let id: Int64
            let payload: String

        }
        let rows = try await client.collectDecodedRows(
            "SELECT id, payload FROM \(table) ORDER BY id",
            as: Row.self
        )
        #expect(rows.count == rowCount)
        #expect(rows.first?.payload == payloads[0])
        #expect(rows.last?.payload == payloads[rowCount - 1])

        await Self.dropTable(table, via: client)
    }

    @Test("an empty INSERT (0 columns) is a no-op that doesn't burn a wire round-trip")
    func emptyInsertIsNoOp() async throws {
        let (client, group) = Self.makeClient()
        defer { Task { await client.shutdown(); try? await group.shutdownGracefully() } }
        try await Self.ensureScratchDatabase(via: client)

        let table = Self.uniqueTable("empty_insert")
        try await client.execute("CREATE TABLE \(table) (n Int32) ENGINE = Memory")

        try await client.insert(into: table, columns: [])
        try await client.insert(into: table, blocks: [])

        let stored = try await client.count("SELECT count() FROM \(table)")
        #expect(stored == 0, "empty INSERT must not produce any rows")

        await Self.dropTable(table, via: client)
    }

    @Test("a SELECT with zero matching rows yields an empty decoded-row array without throwing")
    func zeroMatchingRowsReturnsEmptyDecodedArray() async throws {
        let (client, group) = Self.makeClient()
        defer { Task { await client.shutdown(); try? await group.shutdownGracefully() } }
        try await Self.ensureScratchDatabase(via: client)

        let table = Self.uniqueTable("empty_select")
        try await client.execute("""
            CREATE TABLE \(table) (id Int64, payload String) ENGINE = MergeTree ORDER BY id
            """)
        try await client.insert(into: table, columns: [
            .init(name: "id", values: .int64([1, 2, 3])),
            .init(name: "payload", values: .string(["a", "b", "c"])),
        ])

        struct Row: Decodable {

            let id: Int64
            let payload: String

        }
        let rows = try await client.collectDecodedRows(
            "SELECT id, payload FROM \(table) WHERE id = 9999",
            as: Row.self
        )
        #expect(rows.isEmpty)

        await Self.dropTable(table, via: client)
    }

    @Test("tuning matrix: maxThreads × maxBlockSize on a 500k-row aggregation prints a comparative throughput grid")
    func tuningMatrixAggregation() async throws {
        let (client, group) = Self.makeClient()
        defer { Task { await client.shutdown(); try? await group.shutdownGracefully() } }
        try await Self.ensureScratchDatabase(via: client)

        let table = Self.uniqueTable("tuning")
        try await client.execute("""
            CREATE TABLE \(table) (n UInt64, payload String) ENGINE = MergeTree ORDER BY n
            """)

        let rowCount = 500_000
        let perBatch = 50_000
        var blocks: [[ClickHouseColumnEntry]] = []
        for batch in 0..<(rowCount / perBatch) {
            let base = UInt64(batch * perBatch)
            let ids = (0..<perBatch).map { base + UInt64($0) }
            let payloads = (0..<perBatch).map { "row-\(base + UInt64($0))" }
            blocks.append([
                .init(name: "n", values: .uint64(ids)),
                .init(name: "payload", values: .string(payloads)),
            ])
        }
        try await client.insert(into: table, blocks: blocks)

        let threadCounts = [1, 2, 4, 8]
        let blockSizes = [1_024, 8_192, 65_536, 262_144]
        let aggregation = "SELECT toInt64(count()) FROM \(table) WHERE n % 17 = 0"

        print("[ch-tuning] aggregation over \(rowCount) rows (n % 17 = 0)")
        print("[ch-tuning] block_size │ threads=1     2     4     8")
        for blockSize in blockSizes {
            var line = "[ch-tuning] \(String(format: "%9d", blockSize)) │ "
            for threads in threadCounts {
                _ = try await client.scalarInt64(aggregation, settings: [
                    .maxThreads(threads), .maxBlockSize(blockSize),
                ])
                let measureStarted = Date()
                _ = try await client.scalarInt64(aggregation, settings: [
                    .maxThreads(threads), .maxBlockSize(blockSize),
                ])
                let elapsedMillis = Int((Date().timeIntervalSince(measureStarted) * 1000).rounded())
                line += "\(String(format: "%4d ms", elapsedMillis)) "
            }
            print(line)
        }

        await Self.dropTable(table, via: client)
    }

    @Test("INSERT throughput matrix: batch size 1k vs 10k vs 100k against the same wall clock budget")
    func insertBatchSizeMatrix() async throws {
        let (client, group) = Self.makeClient()
        defer { Task { await client.shutdown(); try? await group.shutdownGracefully() } }
        try await Self.ensureScratchDatabase(via: client)

        print("[ch-insert-matrix] batch │ wall-clock seconds for 100k rows total")
        for batchSize in [1_000, 10_000, 100_000] {
            let table = Self.uniqueTable("insertmatrix_\(batchSize)")
            try await client.execute("""
                CREATE TABLE \(table) (n UInt64, payload String) ENGINE = MergeTree ORDER BY n
                """)

            let totalRows = 100_000
            let batches = totalRows / batchSize
            var blocks: [[ClickHouseColumnEntry]] = []
            for batch in 0..<batches {
                let base = UInt64(batch * batchSize)
                let ids = (0..<batchSize).map { base + UInt64($0) }
                let payloads = (0..<batchSize).map { "v-\(base + UInt64($0))" }
                blocks.append([
                    .init(name: "n", values: .uint64(ids)),
                    .init(name: "payload", values: .string(payloads)),
                ])
            }

            let started = Date()
            try await client.insert(into: table, blocks: blocks)
            let elapsed = Date().timeIntervalSince(started)
            print("[ch-insert-matrix] \(String(format: "%6d", batchSize)) │ \(String(format: "%.3f", elapsed))s")

            await Self.dropTable(table, via: client)
        }
    }

    @Test("a client configured with acquireTimeout=.failImmediatelyWhenExhausted and a full pool surfaces .poolExhausted immediately on the next acquire — this regression-pins the current default; if the lib changes the default to a sane value, this test will fail and signal the production-readiness note has shipped")
    func failImmediatelyAcquireTimeoutPoolExhaustsImmediately() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: Self.host, port: Self.port)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            maxConnections: 1,
            eventLoopGroup: group
        ))
        defer { Task { await client.shutdown() } }
        try await Self.ensureScratchDatabase(via: client)

        let blocker = Task {
            try await client.execute("SELECT sleep(3)")
        }
        try await Task.sleep(for: .milliseconds(150))

        var thrown: Error?
        do {
            _ = try await client.scalarInt64("SELECT toInt64(1)")
        } catch {
            thrown = error
        }
        _ = try? await blocker.value

        let received = try #require(thrown, "with acquireTimeout=.failImmediatelyWhenExhausted, a full pool must surface poolExhausted")
        guard case ClickHouseError.poolExhausted(let cap) = received else {
            Issue.record("expected poolExhausted, got \(received)")
            return
        }
        #expect(cap == 1)
    }

    @Test("decoded-row streaming holds the row count and final-row identity for a 50k-row dataset")
    func bulkDecodedRowStreamingPreservesAllRows() async throws {
        let (client, group) = Self.makeClient()
        defer { Task { await client.shutdown(); try? await group.shutdownGracefully() } }
        try await Self.ensureScratchDatabase(via: client)

        let table = Self.uniqueTable("decoded_bulk")
        try await client.execute("""
            CREATE TABLE \(table) (
              id Int64,
              s  String
            ) ENGINE = MergeTree ORDER BY id
            """)

        let rowCount = 50_000
        let ids = (0..<rowCount).map { Int64($0) }
        let strings = (0..<rowCount).map { String(format: "v-%07d", $0) }
        try await client.insert(into: table, columns: [
            .init(name: "id", values: .int64(ids)),
            .init(name: "s",  values: .string(strings)),
        ])

        struct Row: Decodable {

            let id: Int64
            let s: String

        }

        let rows = try await client.collectDecodedRows(
            "SELECT id, s FROM \(table) ORDER BY id",
            as: Row.self
        )

        #expect(rows.count == rowCount)
        #expect(rows.first?.id == 0)
        #expect(rows.last?.id == Int64(rowCount - 1))
        let middle = rows[rowCount / 2]
        #expect(middle.s == String(format: "v-%07d", rowCount / 2))

        await Self.dropTable(table, via: client)
    }

}
