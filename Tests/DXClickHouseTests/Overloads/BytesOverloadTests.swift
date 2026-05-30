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

// Bytes input form for every public operation on ClickHouseClient that
// accepts a SQL or payload in raw [UInt8] form.
@Suite(
    "ClickHouseClient bytes [UInt8] overload coverage",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseClientBytesOverloadTests {

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

    struct IDRow: Codable, Sendable, Equatable {
        let v: UInt64
    }

    @Test("execute([UInt8]) runs UTF-8 SQL bytes")
    func executeBytes() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute(Array("SELECT 1".utf8))
    }

    @Test("execute([UInt8]) accepts a timeout override")
    func executeBytesWithTimeout() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute(Array("SELECT 1".utf8), timeout: .seconds(5))
    }

    @Test("scalar([UInt8], as:) decodes from bytes form")
    func scalarBytes() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar(
            Array("SELECT toUInt64(99)".utf8),
            as: UInt64.self
        )
        #expect(value == 99)
    }

    @Test("scalar([UInt8], as:, timeout:) decodes with a timeout override")
    func scalarBytesWithTimeout() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar(
            Array("SELECT toUInt64(101)".utf8),
            as: UInt64.self,
            timeout: .seconds(5)
        )
        #expect(value == 101)
    }

    @Test("select([UInt8], as:) streams rows from bytes form")
    func selectBytesStream() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let bytes = Array("SELECT toUInt64(number) AS v FROM numbers(3)".utf8)
        var rows: [IDRow] = []
        for try await row in client.select(bytes, as: IDRow.self) {
            rows.append(row)
        }
        #expect(rows.map(\.v) == [0, 1, 2])
    }

    @Test("selectAll([UInt8], as:) materializes via bytes form")
    func selectAllBytes() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let bytes = Array("SELECT toUInt64(number) AS v FROM numbers(4)".utf8)
        let rows = try await client.selectAll(bytes, as: IDRow.self)
        #expect(rows.map(\.v) == [0, 1, 2, 3])
    }

    @Test("selectAll([UInt8], as:, timeout:) accepts a timeout override")
    func selectAllBytesWithTimeout() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let bytes = Array("SELECT toUInt64(number) AS v FROM numbers(2)".utf8)
        let rows = try await client.selectAll(bytes, as: IDRow.self, timeout: .seconds(5))
        #expect(rows.count == 2)
    }

    @Test("stream([UInt8], handler:) delivers rows via DXMessageHandler")
    func streamBytesHandler() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let collector = ClickHouseClientStreamTests.RowCollector()
        let bytes = Array("SELECT toUInt64(number) AS v FROM numbers(3)".utf8)
        let task = client.stream(
            bytes,
            as: ClickHouseClientStreamTests.IDRow.self,
            handler: collector
        )
        await task.value
        let snapshot = await collector.snapshot()
        #expect(snapshot.rows.map(\.v) == [0, 1, 2])
    }

    @Test("insertNativeBlock(into:columnList:nativeBlockBytes:) accepts raw native-block bytes")
    func insertNativeBlockBytes() async throws {
        let table = Self.uniqueTableName("native_block_bytes")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (v UInt64) ENGINE = Memory")
        // Empty native-block bytes: the server accepts the empty data
        // packet (no rows), and the call must succeed with zero rowsSent.
        let summary = try await client.insertNativeBlock(
            into: table,
            columnList: "(v)",
            nativeBlockBytes: []
        )
        #expect(summary.rowsSent == 0)
        try await client.execute("DROP TABLE \(table)")
    }
}
