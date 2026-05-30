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

// Codable input form for select / selectAll / scalar / insert. Each
// test arranges a fixture, calls the Codable-shaped overload, and
// asserts the typed result matches the round-tripped values.
@Suite(
    "ClickHouseClient Codable overload coverage",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseClientCodableOverloadTests {

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

    struct Order: Codable, Sendable, Equatable {
        let id: UInt64
        let buyer: String
        let amount: Double
    }

    @Test("scalar(_:as:) decodes a Codable-conforming primitive (UInt64)")
    func scalarCodablePrimitive() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar("SELECT toUInt64(2026)", as: UInt64.self)
        #expect(value == 2026)
    }

    @Test("scalar(_:as:) decodes a Codable String primitive")
    func scalarCodableString() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar("SELECT 'codable'", as: String.self)
        #expect(value == "codable")
    }

    @Test("select(_:as:) streams Codable struct rows")
    func selectCodableStruct() async throws {
        let table = Self.uniqueTableName("codable_select")
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
        let expected = [
            Order(id: 1, buyer: "alice", amount: 1.0),
            Order(id: 2, buyer: "bob", amount: 2.0),
        ]
        _ = try await client.insert(into: table, rows: expected)
        var observed: [Order] = []
        for try await row in client.select(
            "SELECT id, buyer, amount FROM \(table) ORDER BY id",
            as: Order.self
        ) {
            observed.append(row)
        }
        #expect(observed == expected)
        try await client.execute("DROP TABLE \(table)")
    }

    @Test("selectAll(_:as:) materializes Codable struct rows into an Array")
    func selectAllCodableStruct() async throws {
        let table = Self.uniqueTableName("codable_select_all")
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
        let expected = [
            Order(id: 10, buyer: "carol", amount: 9.99),
            Order(id: 11, buyer: "dave", amount: 1.99),
            Order(id: 12, buyer: "erin", amount: 4.5),
        ]
        _ = try await client.insert(into: table, rows: expected)
        let observed = try await client.selectAll(
            "SELECT id, buyer, amount FROM \(table) ORDER BY id",
            as: Order.self
        )
        #expect(observed == expected)
        try await client.execute("DROP TABLE \(table)")
    }

    @Test("insert(into:rows:) accepts a Codable struct array")
    func insertCodableArray() async throws {
        let table = Self.uniqueTableName("codable_insert")
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
        let summary = try await client.insert(
            into: table,
            rows: [
                Order(id: 100, buyer: "frank", amount: 0.0),
                Order(id: 200, buyer: "grace", amount: 3.14),
            ]
        )
        #expect(summary.rowsSent == 2)
        let count = try await client.scalar("SELECT toUInt64(count()) FROM \(table)", as: UInt64.self)
        #expect(count == 2)
        try await client.execute("DROP TABLE \(table)")
    }
}
