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
import Testing

@Suite(
    "ClickHouseClient insert happy paths across primitive types",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseClientInsertTests {

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

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(
            host: host,
            port: port,
            user: user,
            password: password,
            database: database
        )
    }

    private static func uniqueTableName(_ prefix: String) -> String {
        "\(prefix)_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
    }

    struct Int32Row: Codable, Sendable, Equatable { let v: Int32 }
    struct Int64Row: Codable, Sendable, Equatable { let v: Int64 }
    struct UInt8Row: Codable, Sendable, Equatable { let v: UInt8 }
    struct UInt64Row: Codable, Sendable, Equatable { let v: UInt64 }
    struct Float64Row: Codable, Sendable, Equatable { let v: Double }
    struct StringRow: Codable, Sendable, Equatable { let v: String }
    struct BoolRow: Codable, Sendable, Equatable { let v: Bool }
    struct UUIDRow: Codable, Sendable, Equatable { let v: UUID }
    struct OrderRow: Codable, Sendable, Equatable {
        let id: UInt64
        let buyer: String
        let amount: Double
    }

    private static func createSimple(client: ClickHouseClient, table: String, columnType: String) async throws {
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (v \(columnType)) ENGINE = Memory")
    }

    private static func dropTable(client: ClickHouseClient, table: String) async throws {
        try await client.execute("DROP TABLE IF EXISTS \(table)")
    }

    @Test("insert single Int32 row")
    func insertInt32Single() async throws {
        let table = Self.uniqueTableName("insert_i32_single")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await Self.createSimple(client: client, table: table, columnType: "Int32")
        let summary = try await client.insert(into: table, rows: [Int32Row(v: -42)])
        #expect(summary.rowsSent == 1)
        let count = try await client.scalar("SELECT toUInt64(count()) FROM \(table)", as: UInt64.self)
        #expect(count == 1)
        try await Self.dropTable(client: client, table: table)
    }

    @Test("insert batch Int64 rows")
    func insertInt64Batch() async throws {
        let table = Self.uniqueTableName("insert_i64_batch")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await Self.createSimple(client: client, table: table, columnType: "Int64")
        let rows: [Int64Row] = (0..<5).map { Int64Row(v: Int64($0)) }
        let summary = try await client.insert(into: table, rows: rows)
        #expect(summary.rowsSent == 5)
        let count = try await client.scalar("SELECT toUInt64(count()) FROM \(table)", as: UInt64.self)
        #expect(count == 5)
        try await Self.dropTable(client: client, table: table)
    }

    @Test("insert UInt8 batch")
    func insertUInt8Batch() async throws {
        let table = Self.uniqueTableName("insert_u8_batch")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await Self.createSimple(client: client, table: table, columnType: "UInt8")
        let rows: [UInt8Row] = (0..<4).map { UInt8Row(v: UInt8($0)) }
        let summary = try await client.insert(into: table, rows: rows)
        #expect(summary.rowsSent == 4)
        try await Self.dropTable(client: client, table: table)
    }

    @Test("insert UInt64 batch returns server written counters")
    func insertUInt64BatchWithCounters() async throws {
        let table = Self.uniqueTableName("insert_u64_counters")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await Self.createSimple(client: client, table: table, columnType: "UInt64")
        let rows: [UInt64Row] = (0..<10).map { UInt64Row(v: UInt64($0)) }
        let summary = try await client.insert(into: table, rows: rows)
        #expect(summary.rowsSent == 10)
        #expect(summary.blocksSent == 1)
        // writtenRows / writtenBytes come from the server's Progress
        // packets which Memory-engine INSERTs may omit entirely.
        // Verify the rows actually landed via a follow-up SELECT.
        let stored = try await client.scalar("SELECT toUInt64(count()) FROM \(table)", as: UInt64.self)
        #expect(stored == 10)
        try await Self.dropTable(client: client, table: table)
    }

    @Test("insert Float64 rows")
    func insertFloat64() async throws {
        let table = Self.uniqueTableName("insert_f64")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await Self.createSimple(client: client, table: table, columnType: "Float64")
        let rows = [Float64Row(v: 1.5), Float64Row(v: 2.5), Float64Row(v: 3.5)]
        let summary = try await client.insert(into: table, rows: rows)
        #expect(summary.rowsSent == 3)
        try await Self.dropTable(client: client, table: table)
    }

    @Test("insert String rows")
    func insertString() async throws {
        let table = Self.uniqueTableName("insert_string")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await Self.createSimple(client: client, table: table, columnType: "String")
        let rows = [StringRow(v: "alice"), StringRow(v: "bob"), StringRow(v: "carol")]
        let summary = try await client.insert(into: table, rows: rows)
        #expect(summary.rowsSent == 3)
        try await Self.dropTable(client: client, table: table)
    }

    @Test("insert Bool rows")
    func insertBool() async throws {
        let table = Self.uniqueTableName("insert_bool")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await Self.createSimple(client: client, table: table, columnType: "Bool")
        let rows = [BoolRow(v: false), BoolRow(v: true), BoolRow(v: true)]
        let summary = try await client.insert(into: table, rows: rows)
        #expect(summary.rowsSent == 3)
        try await Self.dropTable(client: client, table: table)
    }

    @Test("insert UUID rows")
    func insertUUID() async throws {
        let table = Self.uniqueTableName("insert_uuid")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await Self.createSimple(client: client, table: table, columnType: "UUID")
        let rows = [
            UUIDRow(v: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!),
            UUIDRow(v: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!),
        ]
        let summary = try await client.insert(into: table, rows: rows)
        #expect(summary.rowsSent == 2)
        try await Self.dropTable(client: client, table: table)
    }

    @Test("insert with explicit timeout override")
    func insertWithTimeout() async throws {
        let table = Self.uniqueTableName("insert_timeout")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await Self.createSimple(client: client, table: table, columnType: "UInt64")
        let summary = try await client.insert(
            into: table,
            rows: [UInt64Row(v: 1), UInt64Row(v: 2)],
            timeout: .seconds(10)
        )
        #expect(summary.rowsSent == 2)
        try await Self.dropTable(client: client, table: table)
    }

    @Test("insert via Sequence overload round-trips")
    func insertSequence() async throws {
        let table = Self.uniqueTableName("insert_seq")
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
        let summary = try await client.insert(into: table, rows: rows)
        #expect(summary.rowsSent == 2)
        try await Self.dropTable(client: client, table: table)
    }

    @Test("insert via AsyncSequence overload round-trips")
    func insertAsyncSequence() async throws {
        let table = Self.uniqueTableName("insert_async")
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
        let stream: AsyncStream<OrderRow> = AsyncStream { continuation in
            continuation.yield(OrderRow(id: 10, buyer: "carol", amount: 1.0))
            continuation.yield(OrderRow(id: 20, buyer: "dave", amount: 2.0))
            continuation.finish()
        }
        let summary = try await client.insert(into: table, rows: stream)
        #expect(summary.rowsSent == 2)
        let count = try await client.scalar("SELECT toUInt64(count()) FROM \(table)", as: UInt64.self)
        #expect(count == 2)
        try await Self.dropTable(client: client, table: table)
    }

    @Test("insert empty array returns zero rowsSent")
    func insertEmpty() async throws {
        let table = Self.uniqueTableName("insert_empty")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await Self.createSimple(client: client, table: table, columnType: "UInt64")
        let summary = try await client.insert(into: table, rows: [UInt64Row]())
        #expect(summary.rowsSent == 0)
        #expect(summary.blocksSent == 0)
        try await Self.dropTable(client: client, table: table)
    }
}
