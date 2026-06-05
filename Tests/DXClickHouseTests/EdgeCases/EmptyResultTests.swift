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

// A SELECT returning zero rows is a valid result that must NOT throw.
// Every reader API (select stream, selectAll, scalar) has its own
// expected behaviour for the empty case; this suite pins each one.
@Suite(
    "Empty-result SELECTs produce empty/error states without crashing",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseEmptyResultTests {

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

    @Test("select stream yields nothing for a zero-row query")
    func selectStreamEmpty() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        var count = 0
        for try await _ in client.select(
            "SELECT toUInt64(number) AS v FROM numbers(0)",
            as: UInt64Row.self
        ) {
            count += 1
        }
        #expect(count == 0)
    }

    @Test("selectAll returns an empty array for a zero-row query")
    func selectAllEmpty() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let rows = try await client.selectAll(
            "SELECT toUInt64(number) AS v FROM numbers(0)",
            as: UInt64Row.self
        )
        #expect(rows.isEmpty)
    }

    @Test("selectAll returns empty array for filtered-to-zero result")
    func selectAllFilteredEmpty() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let rows = try await client.selectAll(
            "SELECT toString(number) AS v FROM numbers(10) WHERE number > 100",
            as: StringRow.self
        )
        #expect(rows.isEmpty)
    }

    @Test("scalar throws .protocolError on zero rows (cannot synthesize a value)")
    func scalarOnEmptyThrows() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        var caught: ClickHouseError?
        do {
            _ = try await client.scalar("SELECT toUInt64(number) FROM numbers(0)", as: UInt64.self)
            Issue.record("scalar over zero rows must throw")
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

    @Test("Iterating an empty stream and consuming it twice is safe")
    func emptyStreamIsOneShot() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let stream = client.select("SELECT toUInt64(number) AS v FROM numbers(0)", as: UInt64Row.self)
        var first = 0
        for try await _ in stream { first += 1 }
        #expect(first == 0)
    }

    @Test("execute over a zero-row SELECT succeeds")
    func executeOverEmptySelect() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("SELECT * FROM numbers(0)")
    }
}
