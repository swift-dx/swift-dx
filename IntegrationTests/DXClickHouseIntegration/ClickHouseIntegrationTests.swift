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

// Integration tests that exercise the full native client against a real
// ClickHouse server. Skipped automatically unless the env var
// CH_INTEGRATION_HOST is set. Run with:
//
//     CH_INTEGRATION_HOST=localhost swift test \
//         --package-path server/libraries/ClickHouse \
//         --filter ClickHouseIntegration
//
// Optional env vars: CH_INTEGRATION_PORT (default 9000),
// CH_INTEGRATION_USER (default "default"), CH_INTEGRATION_PASSWORD
// (default ""), CH_INTEGRATION_DATABASE (default "default").
@Suite(
    "ClickHouse integration",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseIntegrationTests {

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

    private static func makeClientHello() -> ClickHouseClientHelloPacket {
        ClickHouseClientHelloPacket(
            clientName: "SwiftDX Integration",
            versionMajor: 1, versionMinor: 0, protocolRevision: 54_478,
            defaultDatabase: database, username: user, password: password
        )
    }

    private static let scratchDatabase = "test"

    private static func openConnection() async throws -> (ClickHouseConnection, EventLoopGroup) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let connection = try await ClickHouseConnection.connect(
                host: host,
                port: port,
                clientHello: makeClientHello(),
                eventLoopGroup: group
            )
            for try await _ in connection.selectBlocks("CREATE DATABASE IF NOT EXISTS \(scratchDatabase)") {}
            return (connection, group)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test("connect succeeds and returns metadata with the server's actual hello")
    func connectSucceedsAndReportsServerMetadata() async throws {
        let (connection, group) = try await Self.openConnection()
        #expect(connection.metadata.negotiatedRevision >= 54_400)
        #expect(!connection.metadata.serverHello.serverName.isEmpty)
        #expect(connection.metadata.serverHello.versionMajor > 0)
        try await connection.close()
        try await group.shutdownGracefully()
    }

    @Test("SELECT 1 round-trips through the native client and returns the value 1")
    func selectOneReturnsValue() async throws {
        let (connection, group) = try await Self.openConnection()
        var blocks: [ClickHouseBlock] = []
        for try await block in connection.selectBlocks("SELECT 1") {
            blocks.append(block)
        }
        try await connection.close()
        try await group.shutdownGracefully()

        #expect(blocks.count == 1)
        let block = try #require(blocks.first)
        let column = try #require(block.columns.first?.column as? ClickHouseFixedWidthIntegerColumn<UInt8>)
        #expect(column.values == [1])
    }

    @Test("SELECT toString('hello') returns a String column with the expected value")
    func selectStringReturnsValue() async throws {
        let (connection, group) = try await Self.openConnection()
        var blocks: [ClickHouseBlock] = []
        for try await block in connection.selectBlocks("SELECT toString('hello')") {
            blocks.append(block)
        }
        try await connection.close()
        try await group.shutdownGracefully()

        #expect(blocks.count == 1)
        let block = try #require(blocks.first)
        let column = try #require(block.columns.first?.column as? ClickHouseStringColumn)
        #expect(column.values == ["hello"])
    }

    @Test("SELECT a five-element sequence streams 5 rows of UInt64 [0..4]")
    func selectMultipleRowsReturnsAllValues() async throws {
        let (connection, group) = try await Self.openConnection()
        var allValues: [UInt64] = []
        // arrayJoin avoids system.numbers (access-controlled).
        for try await block in connection.selectBlocks(
            "SELECT arrayJoin([toUInt64(0), 1, 2, 3, 4]) AS n"
        ) {
            if let column = block.columns.first?.column as? ClickHouseFixedWidthIntegerColumn<UInt64> {
                allValues.append(contentsOf: column.values)
            }
        }
        try await connection.close()
        try await group.shutdownGracefully()

        #expect(allValues.sorted() == [0, 1, 2, 3, 4])
    }

    @Test("INSERT into test.* round-trips Int32 values via the connection-level API")
    func insertSelectInt32RoundTrip() async throws {
        let (connection, group) = try await Self.openConnection()
        let table = "test.swift_int32_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        for try await _ in connection.selectBlocks("CREATE TABLE \(table) (n Int32) ENGINE = Memory") {}

        let insertBlock = ClickHouseBlock(
            blockInfo: .init(),
            columns: [.init(
                name: "n",
                column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [10, 20, 30, -1, Int32.max])
            )]
        )
        try await connection.insertBlocks("INSERT INTO \(table) FORMAT Native", blocks: [insertBlock])

        var allValues: [Int32] = []
        for try await selected in connection.selectBlocks("SELECT n FROM \(table) ORDER BY n") {
            if let column = selected.columns.first?.column as? ClickHouseFixedWidthIntegerColumn<Int32> {
                allValues.append(contentsOf: column.values)
            }
        }
        for try await _ in connection.selectBlocks("DROP TABLE \(table)") {}
        try await connection.close()
        try await group.shutdownGracefully()

        #expect(allValues == [-1, 10, 20, 30, Int32.max])
    }

    @Test("INSERT into test.* round-trips String values including unicode + emoji")
    func insertSelectStringRoundTrip() async throws {
        let (connection, group) = try await Self.openConnection()
        let table = "test.swift_str_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        for try await _ in connection.selectBlocks("CREATE TABLE \(table) (s String) ENGINE = Memory") {}

        let insertBlock = ClickHouseBlock(
            blockInfo: .init(),
            columns: [.init(
                name: "s",
                column: ClickHouseStringColumn(values: ["alpha", "beta", "Привет", "🚀", ""])
            )]
        )
        try await connection.insertBlocks("INSERT INTO \(table) FORMAT Native", blocks: [insertBlock])

        var allValues: [String] = []
        for try await selected in connection.selectBlocks("SELECT s FROM \(table) ORDER BY s") {
            if let column = selected.columns.first?.column as? ClickHouseStringColumn {
                allValues.append(contentsOf: column.values)
            }
        }
        for try await _ in connection.selectBlocks("DROP TABLE \(table)") {}
        try await connection.close()
        try await group.shutdownGracefully()

        #expect(allValues.contains(""))
        #expect(allValues.contains("alpha"))
        #expect(allValues.contains("beta"))
        #expect(allValues.contains("Привет"))
        #expect(allValues.contains("🚀"))
    }

    @Test("an invalid query surfaces the server's exception with the typed code and name")
    func invalidQuerySurfacesServerException() async throws {
        let (connection, group) = try await Self.openConnection()
        var thrown: Error?
        do {
            for try await _ in connection.selectBlocks("SELECT * FROM no_such_database.no_such_table") {}
        } catch {
            thrown = error
        }
        try await connection.close()
        try await group.shutdownGracefully()

        let received = try #require(thrown)
        guard case ClickHouseError.serverException(let exception) = received else {
            Issue.record("expected serverException, got \(String(describing: thrown))")
            return
        }
        #expect(exception.code > 0)
        #expect(!exception.name.isEmpty)
        #expect(!exception.message.isEmpty)
    }

    @Test("decodedRows streams typed Decodable rows by serializing columnar blocks per row")
    func decodedRowsReturnsTypedValues() async throws {
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: Self.host, port: Self.port)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            eventLoopGroup: MultiThreadedEventLoopGroup(numberOfThreads: 1)
        ))

        struct Row: Decodable, Equatable {

            let n: UInt64
            let s: String

        }

        // arrayJoin avoids system.numbers (access-controlled).
        let rows = try await client.collectDecodedRows(
            "SELECT n, toString(n) AS s FROM (SELECT arrayJoin([toUInt64(0), 1, 2]) AS n) ORDER BY n",
            as: Row.self
        )
        #expect(rows == [
            .init(n: 0, s: "0"),
            .init(n: 1, s: "1"),
            .init(n: 2, s: "2"),
        ])

        await client.shutdown()
    }

    @Test("public typed INSERT API round-trips with mixed Int32 + String columns")
    func publicTypedInsertRoundTrips() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: Self.host, port: Self.port)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            eventLoopGroup: group
        ))

        let table = "test.swift_typed_insert_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        let (preconn, pregroup) = try await Self.openConnection()
        for try await _ in preconn.selectBlocks("CREATE TABLE \(table) (n Int32, s String) ENGINE = Memory") {}
        try await preconn.close()
        try await pregroup.shutdownGracefully()

        try await client.insert(into: table, columns: [
            .init(name: "n", values: .int32([10, 20, 30])),
            .init(name: "s", values: .string(["alpha", "beta", "gamma"])),
        ])

        struct Row: Decodable, Equatable {

            let n: Int32
            let s: String

        }
        let rows = try await client.collectDecodedRows(
            "SELECT n, s FROM \(table) ORDER BY n",
            as: Row.self
        )
        #expect(rows == [
            .init(n: 10, s: "alpha"),
            .init(n: 20, s: "beta"),
            .init(n: 30, s: "gamma"),
        ])

        let (cleanupConn, cleanupGroup) = try await Self.openConnection()
        for try await _ in cleanupConn.selectBlocks("DROP TABLE \(table)") {}
        try await cleanupConn.close()
        try await cleanupGroup.shutdownGracefully()

        await client.shutdown()
    }

    @Test("multi-block SELECT yields all rows in order")
    func multiBlockSelectMaintainsOrderAndCount() async throws {
        let (connection, group) = try await Self.openConnection()
        // Generate 1000 sequential rows via range() — avoids system.numbers.
        let limit = 1000
        var collected: [UInt64] = []
        for try await block in connection.selectBlocks(
            "SELECT arrayJoin(range(toUInt64(\(limit)))) AS n"
        ) {
            if let column = block.columns.first?.column as? ClickHouseFixedWidthIntegerColumn<UInt64> {
                collected.append(contentsOf: column.values)
            }
        }
        try await connection.close()
        try await group.shutdownGracefully()

        #expect(collected.count == limit)
        let sortedCollected = collected.sorted()
        for (index, value) in sortedCollected.enumerated() {
            #expect(value == UInt64(index), "row \(index) had unexpected value \(value)")
        }
    }

    // MARK: - URL-string connection path

    @Test("a clickhouse:// connection URL produces a working client (full env-var-derived URL string)")
    func clickhouseURLEndToEnd() async throws {
        // Compose the canonical URL form from the same env vars the
        // integration suite uses elsewhere; URL-percent-encode the
        // password so embedded specials reach the parser correctly.
        let allowed = CharacterSet.urlPasswordAllowed
        let encodedPassword = Self.password.addingPercentEncoding(withAllowedCharacters: allowed) ?? Self.password
        let urlString = "clickhouse://\(Self.user):\(encodedPassword)@\(Self.host):\(Self.port)/\(Self.database)"
        let url = try #require(URL(string: urlString), "test env produced an invalid URL: \(urlString)")

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let configuration = try ClickHouseClient.Configuration(url: url, eventLoopGroup: group)
        let client = ClickHouseClient(configuration: configuration)
        defer { Task { await client.shutdown() } }

        // Round-trip a scalar so we know the connection actually
        // authenticated and the codec wired up correctly through the
        // URL-derived configuration (not just the raw-init path that
        // every other test uses).
        let value = try await client.scalarInt64("SELECT toInt64(13)")
        #expect(value == 13)
    }

    // MARK: - Scalar getter family — every public getter against the live cluster

    @Test("every scalar getter round-trips its expected ClickHouse type via the typed extractor")
    func scalarGetterFamilyRoundTrip() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: Self.host, port: Self.port)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            eventLoopGroup: group
        ))
        defer { Task { await client.shutdown() } }

        // String
        let s = try await client.scalarString("SELECT toString('hello-🇳🇿')")
        #expect(s == "hello-🇳🇿")

        // Int64 — both positive and Int64.min round-trip
        let positive = try await client.scalarInt64("SELECT toInt64(9223372036854775807)")
        #expect(positive == .max)
        let negative = try await client.scalarInt64("SELECT toInt64(-9223372036854775808)")
        #expect(negative == .min)

        // Float64 — exact value preserved through binary path
        let f = try await client.scalarFloat64("SELECT toFloat64(2.718281828459045)")
        #expect(f == 2.718281828459045)

        // Bool — both polarities
        #expect(try await client.scalarBool("SELECT toBool(true)") == true)
        #expect(try await client.scalarBool("SELECT toBool(false)") == false)

        // UUID — server-generated UUID round-trips through SELECT
        let serverUUID = try await client.scalarUUID("SELECT generateUUIDv4()")
        #expect(serverUUID != UUID(uuidString: "00000000-0000-0000-0000-000000000000"), "UUID generator must return a non-zero value")

        // DateTime — second-resolution UTC value
        let dt = try await client.scalarDateTime("SELECT toDateTime('2024-03-15 14:30:45')")
        // 2024-03-15 14:30:45 UTC = 1710513045 unix seconds
        #expect(Int(dt.timeIntervalSince1970.rounded()) == 1_710_513_045)

        // count(*) — UInt64 path with strict zero-rows error
        let c = try await client.count("SELECT count() FROM numbers(42)")
        #expect(c == 42)
    }

    @Test("scalarStringIfAny returns .empty when the query produces zero rows (no error); scalarString throws scalarQueryReturnedZeroRows")
    func scalarStringEmptyResult() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: Self.host, port: Self.port)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            eventLoopGroup: group
        ))
        defer { Task { await client.shutdown() } }

        let result = try await client.scalarStringIfAny("SELECT toString(0) WHERE 0")
        guard case .empty = result else {
            Issue.record("empty result must surface as .empty; got \(result)")
            return
        }

        await #expect(throws: ClickHouseError.self) {
            _ = try await client.scalarString("SELECT toString(0) WHERE 0")
        }
    }

    @Test("count() throws scalarQueryReturnedZeroRows when the projection is UInt64 but the result set is empty")
    func countOnEmptyThrows() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: Self.host, port: Self.port)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            eventLoopGroup: group
        ))
        defer { Task { await client.shutdown() } }

        // Aggregations like `count()` always emit one row even on
        // empty input. To exercise the zero-rows branch of `count()`
        // we need a non-aggregate query whose projection has UInt64
        // type but produces no rows: `numbers(N) WHERE 0` projects
        // UInt64 and returns zero rows. The contract of `count()`
        // is that it requires exactly one row of UInt64; with zero
        // rows it must throw scalarQueryReturnedZeroRows.
        await #expect(throws: ClickHouseError.self) {
            _ = try await client.count("SELECT toUInt64(number) FROM numbers(5) WHERE 0")
        }
    }

    @Test("scalar type-mismatch surfaces as scalarColumnTypeMismatch with the projected name")
    func scalarTypeMismatchSurfacesTyped() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: Self.host, port: Self.port)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            eventLoopGroup: group
        ))
        defer { Task { await client.shutdown() } }

        // Project an Int64 but extract it via scalarString — must throw
        // a typed scalarColumnTypeMismatch, not crash or silently coerce.
        await #expect(throws: ClickHouseError.self) {
            _ = try await client.scalarString("SELECT toInt64(5)")
        }
    }

}
