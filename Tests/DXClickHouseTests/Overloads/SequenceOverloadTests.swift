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

// Sequence input form for the batch insert overload. Drives the
// `insert<S: Sequence>(into:rows:)` API with a concrete Sendable
// Sequence wrapper that mirrors what downstream callers ship.
@Suite(
    "ClickHouseClient Sequence overload coverage",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseClientSequenceOverloadTests {

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

    struct PointRow: Codable, Sendable, Equatable {
        let v: UInt64
    }

    // Sendable wrapper around an Array, drives the
    // `insert<S: Sequence & Sendable>` overload with a non-Array shape.
    struct SequenceBox: Sequence, Sendable {

        let rows: [PointRow]

        func makeIterator() -> Array<PointRow>.Iterator {
            rows.makeIterator()
        }
    }

    @Test("insert(into:rows:) accepts an Array literal (Sequence path)")
    func insertSequenceFromArray() async throws {
        let table = Self.uniqueTableName("seq_array")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (v UInt64) ENGINE = Memory")
        let summary = try await client.insert(
            into: table,
            rows: [PointRow(v: 1), PointRow(v: 2), PointRow(v: 3)]
        )
        #expect(summary.rowsSent == 3)
        let count = try await client.scalar("SELECT toUInt64(count()) FROM \(table)", as: UInt64.self)
        #expect(count == 3)
        try await client.execute("DROP TABLE \(table)")
    }

    @Test("insert(into:rows:) accepts a custom Sendable Sequence wrapper")
    func insertSequenceFromWrapper() async throws {
        let table = Self.uniqueTableName("seq_wrapper")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (v UInt64) ENGINE = Memory")
        let wrapper = SequenceBox(rows: (10..<14).map { PointRow(v: UInt64($0)) })
        let summary = try await client.insert(into: table, rows: wrapper)
        #expect(summary.rowsSent == 4)
        try await client.execute("DROP TABLE \(table)")
    }

    @Test("insert(into:rows:) Sequence overload accepts a timeout override")
    func insertSequenceWithTimeout() async throws {
        let table = Self.uniqueTableName("seq_timeout")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (v UInt64) ENGINE = Memory")
        let wrapper = SequenceBox(rows: [PointRow(v: 5), PointRow(v: 6)])
        let summary = try await client.insert(
            into: table,
            rows: wrapper,
            timeout: .seconds(10)
        )
        #expect(summary.rowsSent == 2)
        try await client.execute("DROP TABLE \(table)")
    }

    @Test("insert(into:rows:) Sequence overload with empty content reports zero")
    func insertEmptySequence() async throws {
        let table = Self.uniqueTableName("seq_empty")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (v UInt64) ENGINE = Memory")
        let wrapper = SequenceBox(rows: [])
        let summary = try await client.insert(into: table, rows: wrapper)
        #expect(summary.rowsSent == 0)
        try await client.execute("DROP TABLE \(table)")
    }
}
