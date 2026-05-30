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
import DXCore
import Foundation
import Testing

// Live-broker integration cover for the Redis-style overload family on
// ClickHouseClient: execute, ping, scalar, select, insert, stream,
// each in every input form (raw `[UInt8]` SQL, Foundation Codable,
// Sequence, AsyncSequence, callback, DXMessageHandler).
@Suite(
    "DXClickHouse client overload integration",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseClientOverloadIntegration {

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

    struct OrderRow: Codable, Sendable, Equatable {
        let id: UInt64
        let buyer: String
        let amount: Double
    }

    actor CollectingHandler: DXMessageHandler {

        typealias Message = OrderRow
        typealias Failure = ClickHouseError

        private(set) var rows: [OrderRow] = []
        private(set) var failures: [ClickHouseError] = []

        func receive(_ message: OrderRow) async {
            rows.append(message)
        }

        func receive(error: ClickHouseError) async {
            failures.append(error)
        }

        func snapshot() -> (rows: [OrderRow], failures: [ClickHouseError]) {
            (rows, failures)
        }
    }

    @Test("execute(String) round-trips a DDL statement")
    func executeStringRoundTrip() async throws {
        let table = makeTableName(prefix: "raw_overload_exec")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (id UInt64) ENGINE = Memory")
        try await client.execute("DROP TABLE \(table)")
    }

    @Test("execute([UInt8]) round-trips raw SQL bytes")
    func executeBytesRoundTrip() async throws {
        let table = makeTableName(prefix: "raw_overload_exec_bytes")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute(Array("DROP TABLE IF EXISTS \(table)".utf8))
        try await client.execute(Array("CREATE TABLE \(table) (id UInt64) ENGINE = Memory".utf8))
        try await client.execute(Array("DROP TABLE \(table)".utf8))
    }

    @Test("ping() responds without error")
    func pingResponds() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.ping()
    }

    @Test("ping(completion:) delivers a Result.success")
    func pingCallback() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let outcome: ClickHouseError? = await withCheckedContinuation { continuation in
            client.ping { result in
                switch result {
                case .success: continuation.resume(returning: nil)
                case .failure(let error): continuation.resume(returning: error)
                }
            }
        }
        #expect(outcome == nil)
    }

    @Test("scalar([UInt8], as:) decodes a UInt64 from raw SQL bytes")
    func scalarFromSQLBytes() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let bytes = Array("SELECT toUInt64(2026)".utf8)
        let value = try await client.scalar(bytes, as: UInt64.self)
        #expect(value == 2026)
    }

    @Test("scalar callback variant delivers a typed Result")
    func scalarCallback() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let outcome: Result<UInt64, ClickHouseError> = await withCheckedContinuation { continuation in
            client.scalar("SELECT toUInt64(1729)", as: UInt64.self) { result in
                continuation.resume(returning: result)
            }
        }
        switch outcome {
        case .success(let value): #expect(value == 1729)
        case .failure(let error): Issue.record("expected success, got \(error)")
        }
    }

    @Test("select([UInt8], as:) streams rows from raw SQL bytes")
    func selectFromSQLBytes() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let bytes = Array("SELECT toUInt64(number) AS id FROM numbers(5)".utf8)
        struct IDRow: Decodable, Sendable, Equatable { let id: UInt64 }
        var collected: [IDRow] = []
        for try await row in client.select(bytes, as: IDRow.self) {
            collected.append(row)
        }
        #expect(collected.map(\.id) == [0, 1, 2, 3, 4])
    }

    @Test("selectAll(String, as:) collects rows into a typed array")
    func selectAllCollects() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        struct IDRow: Decodable, Sendable, Equatable { let id: UInt64 }
        let rows = try await client.selectAll(
            "SELECT toUInt64(number) AS id FROM numbers(3)",
            as: IDRow.self
        )
        #expect(rows.map(\.id) == [0, 1, 2])
    }

    @Test("select callback variant delivers the full row set")
    func selectCallback() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        struct IDRow: Decodable, Sendable, Equatable { let id: UInt64 }
        let outcome: Result<[IDRow], ClickHouseError> = await withCheckedContinuation { continuation in
            client.select("SELECT toUInt64(number) AS id FROM numbers(4)", as: IDRow.self) { result in
                continuation.resume(returning: result)
            }
        }
        switch outcome {
        case .success(let rows): #expect(rows.map(\.id) == [0, 1, 2, 3])
        case .failure(let error): Issue.record("expected success, got \(error)")
        }
    }

    @Test("insert from Sequence converts and round-trips")
    func insertFromSequence() async throws {
        let table = makeTableName(prefix: "raw_overload_seq")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("""
            CREATE TABLE \(table) (
                id UInt64,
                buyer String,
                amount Float64
            ) ENGINE = Memory
            """)
        let rows: [OrderRow] = [
            OrderRow(id: 1, buyer: "alice", amount: 9.99),
            OrderRow(id: 2, buyer: "bob", amount: 42.5),
        ]
        // Drives the `insert<S: Sequence>` overload via a concrete
        // Sendable collection (Array literal). AnySequence is not
        // Sendable so we cannot use it directly here.
        let summary = try await client.insert(into: table, rows: rows)
        #expect(summary.rowsSent == 2)
        let count = try await client.scalar("SELECT toUInt64(count()) FROM \(table)", as: UInt64.self)
        #expect(count == 2)
        try await client.execute("DROP TABLE \(table)")
    }

    @Test("insert from AsyncSequence drains and round-trips")
    func insertFromAsyncSequence() async throws {
        let table = makeTableName(prefix: "raw_overload_async")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("""
            CREATE TABLE \(table) (
                id UInt64,
                buyer String,
                amount Float64
            ) ENGINE = Memory
            """)
        let stream = Self.asyncRowSource(of: [
            OrderRow(id: 10, buyer: "carol", amount: 1.0),
            OrderRow(id: 20, buyer: "dave", amount: 2.0),
            OrderRow(id: 30, buyer: "erin", amount: 3.0),
        ])
        let summary = try await client.insert(into: table, rows: stream)
        #expect(summary.rowsSent == 3)
        let count = try await client.scalar("SELECT toUInt64(count()) FROM \(table)", as: UInt64.self)
        #expect(count == 3)
        try await client.execute("DROP TABLE \(table)")
    }

    @Test("insert callback variant delivers the summary asynchronously")
    func insertCallback() async throws {
        let table = makeTableName(prefix: "raw_overload_callback")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("""
            CREATE TABLE \(table) (
                id UInt64,
                buyer String,
                amount Float64
            ) ENGINE = Memory
            """)
        let outcome: Result<ClickHouseInsertSummary, ClickHouseError> = await withCheckedContinuation { continuation in
            client.insert(into: table, rows: [
                OrderRow(id: 99, buyer: "frank", amount: 7.5),
            ]) { result in
                continuation.resume(returning: result)
            }
        }
        switch outcome {
        case .success(let summary): #expect(summary.rowsSent == 1)
        case .failure(let error): Issue.record("expected success, got \(error)")
        }
        try await client.execute("DROP TABLE \(table)")
    }

    @Test("stream(handler:) delivers every row through DXMessageHandler")
    func streamHandlerDeliversRows() async throws {
        let table = makeTableName(prefix: "raw_overload_stream")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("""
            CREATE TABLE \(table) (
                id UInt64,
                buyer String,
                amount Float64
            ) ENGINE = Memory
            """)
        let inserted = [
            OrderRow(id: 1, buyer: "a", amount: 0.5),
            OrderRow(id: 2, buyer: "b", amount: 1.5),
            OrderRow(id: 3, buyer: "c", amount: 2.5),
        ]
        _ = try await client.insert(into: table, rows: inserted)
        let handler = CollectingHandler()
        let task = client.stream(
            "SELECT id, buyer, amount FROM \(table) ORDER BY id",
            as: OrderRow.self,
            handler: handler
        )
        await task.value
        let snapshot = await handler.snapshot()
        #expect(snapshot.rows == inserted)
        #expect(snapshot.failures.isEmpty)
        try await client.execute("DROP TABLE \(table)")
    }

    @Test("stream(handler:) surfaces a typed error for an invalid query")
    func streamHandlerSurfacesError() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let handler = CollectingHandler()
        let task = client.stream(
            "SELECT * FROM definitely_not_a_real_table_xyz",
            as: OrderRow.self,
            handler: handler
        )
        await task.value
        let snapshot = await handler.snapshot()
        #expect(snapshot.rows.isEmpty)
        #expect(snapshot.failures.count == 1)
        switch snapshot.failures[0] {
        case .queryFailed: break
        default: Issue.record("expected queryFailed, got \(snapshot.failures[0])")
        }
    }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(
            host: host, port: port,
            user: user, password: password, database: database
        )
    }

    private func makeTableName(prefix: String) -> String {
        "\(prefix)_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
    }

    private static func asyncRowSource(of rows: [OrderRow]) -> AsyncStream<OrderRow> {
        AsyncStream { continuation in
            for row in rows { continuation.yield(row) }
            continuation.finish()
        }
    }
}
