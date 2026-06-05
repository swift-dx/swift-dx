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

// SELECTs that project exactly one column. The scalar(_:as:) overload
// exists specifically for this shape; selectAll / select also handle
// it correctly for any row count.
@Suite(
    "Single-column SELECTs across reader APIs",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseSingleColumnTests {

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

    struct UInt64Row: Decodable, Sendable, Equatable { let v: UInt64 }
    struct StringRow: Decodable, Sendable, Equatable { let v: String }

    @Test("selectAll over a single column returns all rows")
    func selectAllSingleColumnMultipleRows() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let rows = try await client.selectAll(
            "SELECT toUInt64(number) AS v FROM numbers(5)",
            as: UInt64Row.self
        )
        #expect(rows.count == 5)
        #expect(rows.map(\.v) == [0, 1, 2, 3, 4])
    }

    @Test("scalar over a 1x1 single-column result returns the value")
    func scalarSingleColumnSingleRow() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar("SELECT toUInt64(99)", as: UInt64.self)
        #expect(value == 99)
    }

    @Test("select stream over a single column yields rows in order")
    func selectStreamSingleColumn() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        var observed: [UInt64] = []
        for try await row in client.select(
            "SELECT toUInt64(number) AS v FROM numbers(3)",
            as: UInt64Row.self
        ) {
            observed.append(row.v)
        }
        #expect(observed == [0, 1, 2])
    }

    @Test("single-column String SELECT decodes long strings correctly")
    func singleColumnLongString() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let longLiteral = String(repeating: "abcdefgh", count: 512)
        let escapedForSql = longLiteral.replacingOccurrences(of: "'", with: "''")
        let result = try await client.scalar(
            "SELECT '\(escapedForSql)'",
            as: String.self
        )
        #expect(result == longLiteral)
    }

    @Test("single-column SELECT with an aggregate decodes one value per group")
    func singleColumnAggregate() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let total = try await client.scalar(
            "SELECT toUInt64(count()) FROM numbers(100)",
            as: UInt64.self
        )
        #expect(total == 100)
    }
}
