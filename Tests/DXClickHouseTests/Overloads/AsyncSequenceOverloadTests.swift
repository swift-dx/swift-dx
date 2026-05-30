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

// AsyncSequence input form drives `insert<Source: AsyncSequence>`. The
// select-side AsyncSequence form is the natural AsyncThrowingStream
// produced by `select(_:as:)` and is covered separately.
@Suite(
    "ClickHouseClient AsyncSequence overload coverage",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseClientAsyncSequenceOverloadTests {

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

    private static func asyncSource(of rows: [PointRow]) -> AsyncStream<PointRow> {
        AsyncStream { continuation in
            for row in rows { continuation.yield(row) }
            continuation.finish()
        }
    }

    @Test("insert(into:rows:) accepts an AsyncStream source")
    func insertAsyncStream() async throws {
        let table = Self.uniqueTableName("async_stream")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (v UInt64) ENGINE = Memory")
        let source = Self.asyncSource(of: (0..<6).map { PointRow(v: UInt64($0)) })
        let summary = try await client.insert(into: table, rows: source)
        #expect(summary.rowsSent == 6)
        let count = try await client.scalar("SELECT toUInt64(count()) FROM \(table)", as: UInt64.self)
        #expect(count == 6)
        try await client.execute("DROP TABLE \(table)")
    }

    @Test("insert(into:rows:) AsyncSequence overload accepts a timeout override")
    func insertAsyncStreamWithTimeout() async throws {
        let table = Self.uniqueTableName("async_stream_timeout")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (v UInt64) ENGINE = Memory")
        let source = Self.asyncSource(of: [PointRow(v: 1), PointRow(v: 2)])
        let summary = try await client.insert(into: table, rows: source, timeout: .seconds(10))
        #expect(summary.rowsSent == 2)
        try await client.execute("DROP TABLE \(table)")
    }

    @Test("insert(into:rows:) AsyncSequence overload accepts an empty source")
    func insertEmptyAsyncStream() async throws {
        let table = Self.uniqueTableName("async_stream_empty")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (v UInt64) ENGINE = Memory")
        let source = Self.asyncSource(of: [])
        let summary = try await client.insert(into: table, rows: source)
        #expect(summary.rowsSent == 0)
        try await client.execute("DROP TABLE \(table)")
    }

    @Test("select(_:as:) AsyncThrowingStream consumes 25 rows")
    func selectAsyncThrowingStreamConsumes() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        var count = 0
        for try await _ in client.select("SELECT toUInt64(number) AS v FROM numbers(25)", as: PointRow.self) {
            count += 1
        }
        #expect(count == 25)
    }
}
