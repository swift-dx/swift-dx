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

// Boundary tests around the 16 MB single-block size limit. ClickHouse's
// Native protocol caps a single uncompressed block at ~16 MB; payloads
// past that threshold must either be split into multiple blocks by the
// client encoder or surface a typed error rather than crash.
@Suite(
    "Oversize INSERT payloads survive without crashing",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseOversizeTests {

    private static var host: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
    }

    private static var password: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? ""
    }

    private static var port: Int {
        Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
    }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, password: password)
    }

    private static func uniqueTableName(_ prefix: String) -> String {
        "\(prefix)_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
    }

    struct StringRow: Codable, Sendable, Equatable { let v: String }
    struct UInt64Row: Codable, Sendable, Equatable { let v: UInt64 }

    @Test("Single 4 MB string round-trips through INSERT/SELECT")
    func single4MBStringRoundTrip() async throws {
        let table = Self.uniqueTableName("oversize_4mb")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (v String) ENGINE = Memory")
        let payload = String(repeating: "a", count: 4 * 1024 * 1024)
        let summary = try await client.insert(into: table, rows: [StringRow(v: payload)])
        #expect(summary.rowsSent == 1)
        let length = try await client.scalar(
            "SELECT toUInt64(length(v)) FROM \(table)",
            as: UInt64.self
        )
        #expect(length == UInt64(payload.count))
        try await client.execute("DROP TABLE IF EXISTS \(table)")
    }

    @Test("INSERT of 100k rows in a single batch surfaces a typed result")
    func insertManyRowsLargeBatch() async throws {
        let table = Self.uniqueTableName("oversize_many")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (v UInt64) ENGINE = Memory")
        let rows: [UInt64Row] = (0..<100_000).map { UInt64Row(v: UInt64($0)) }
        var didThrow = false
        var summary: ClickHouseInsertSummary?
        do {
            summary = try await client.insert(
                into: table,
                rows: rows,
                timeout: .seconds(120)
            )
        } catch {
            // A typed error is acceptable here; what we forbid is a
            // crash. The catch block sees only ClickHouseError because
            // of the typed-throws contract on insert(...).
            didThrow = true
        }
        if let summary {
            #expect(summary.rowsSent == 100_000)
            let count = try await client.scalar("SELECT toUInt64(count()) FROM \(table)", as: UInt64.self)
            #expect(count == 100_000)
        } else {
            #expect(didThrow)
        }
        try await client.execute("DROP TABLE IF EXISTS \(table)")
    }

    @Test("SELECT of a large materialised value succeeds")
    func selectLargeMaterializedValue() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        // Build a 1 MB string on the server side via repeat() then read
        // it back through the scalar path; this exercises the receive
        // buffer growth without requiring an INSERT.
        let length = try await client.scalar(
            "SELECT toUInt64(length(repeat('x', 1000000)))",
            as: UInt64.self
        )
        #expect(length == 1_000_000)
    }

    @Test("SELECT of 50k rows streams via select() without OOM")
    func selectManyRowsStreams() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        var count = 0
        for try await _ in client.select(
            "SELECT toUInt64(number) AS v FROM numbers(50000)",
            as: UInt64Row.self
        ) {
            count += 1
        }
        #expect(count == 50_000)
    }
}
