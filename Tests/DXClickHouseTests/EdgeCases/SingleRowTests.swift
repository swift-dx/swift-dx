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

// SELECT that returns exactly one row, across every reader API. The
// 1-row case is the canonical boundary that scalar() consumes; we
// also pin the array and stream behaviour at that count.
@Suite(
    "Single-row SELECTs across every reader API",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseSingleRowTests {

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
    struct TwoColRow: Decodable, Sendable, Equatable { let a: UInt32; let b: String }

    @Test("select stream yields exactly one row for a 1-row query")
    func selectStreamSingleRow() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        var rows: [UInt64Row] = []
        for try await row in client.select(
            "SELECT toUInt64(42) AS v",
            as: UInt64Row.self
        ) {
            rows.append(row)
        }
        #expect(rows == [UInt64Row(v: 42)])
    }

    @Test("selectAll returns a one-element array for a 1-row query")
    func selectAllSingleRow() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let rows = try await client.selectAll(
            "SELECT toUInt64(42) AS v",
            as: UInt64Row.self
        )
        #expect(rows == [UInt64Row(v: 42)])
    }

    @Test("scalar returns the value of a 1x1 result")
    func scalarSingleRow() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar("SELECT toUInt64(42)", as: UInt64.self)
        #expect(value == 42)
    }

    @Test("scalar returns a String value for a 1x1 string result")
    func scalarStringSingleRow() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar("SELECT 'hello world'", as: String.self)
        #expect(value == "hello world")
    }

    @Test("scalar throws .protocolError when SELECT returns 2 rows")
    func scalarMoreThanOneRowThrows() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        var caught: ClickHouseError?
        do {
            _ = try await client.scalar(
                "SELECT toUInt64(number) FROM numbers(2)",
                as: UInt64.self
            )
            Issue.record("scalar must reject multi-row results")
        } catch let error {
            caught = error
        }
        switch caught {
        case .some(.protocolError):
            break
        default:
            Issue.record("expected .protocolError, got \(String(describing: caught))")
        }
    }

    @Test("scalar throws .protocolError when SELECT returns 2 columns")
    func scalarMoreThanOneColumnThrows() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        var caught: ClickHouseError?
        do {
            _ = try await client.scalar(
                "SELECT 1, 2",
                as: UInt8.self
            )
            Issue.record("scalar must reject multi-column results")
        } catch let error {
            caught = error
        }
        switch caught {
        case .some(.protocolError):
            break
        default:
            Issue.record("expected .protocolError, got \(String(describing: caught))")
        }
    }

    @Test("selectAll over a single 2-column row decodes both fields")
    func selectAllTwoColumnSingleRow() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let rows = try await client.selectAll(
            "SELECT toUInt32(7) AS a, 'seven' AS b",
            as: TwoColRow.self
        )
        #expect(rows == [TwoColRow(a: 7, b: "seven")])
    }
}
