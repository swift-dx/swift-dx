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

// Sad-path coverage for client-side decoding when the server (or a
// caller-issued query) produces a shape the typed Codable layer cannot
// satisfy. These tests deliberately ask for a row type that does not
// match the projected columns and confirm the typed error surfaces
// rather than crashing.
@Suite(
    "Malformed-result paths surface typed errors without crashing",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseMalformedTests {

    private static var host: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
    }
    private static var port: Int {
        Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
    }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port)
    }

    struct StringRow: Codable, Sendable { let v: String }
    struct WrongKeyRow: Decodable, Sendable { let nonexistent: String }
    struct WrongTypeRow: Decodable, Sendable { let v: Int8 }

    // Classification of catch-side outcomes so call sites can switch
    // over discrete cases without using `var caught: ClickHouseError?`
    // (the typed-throws + Optional pattern triggers a SILGen bug on
    // Swift 6.3 — see Resilience/TimeoutInteractionTests.swift for the
    // same workaround applied elsewhere).
    private enum DecodingOutcome: Sendable {
        case completed
        case protocolError
        case queryFailed(Int32)
        case other(String)
    }

    private static func classify(_ error: ClickHouseError) -> DecodingOutcome {
        switch error {
        case .protocolError:
            return .protocolError
        case .queryFailed(let exception):
            return .queryFailed(exception.code)
        case .connectionFailed, .socketIOFailed, .unexpectedEOF,
             .reconnectExhausted, .endpointsExhausted, .queryTimeout:
            return .other(String(describing: error))
        }
    }

    @Test("selectAll with a wrong row key throws a typed error")
    func selectWithWrongKeyThrows() async {
        let client: ClickHouseClient
        do {
            client = try await Self.makeClient()
        } catch {
            Issue.record("could not connect: \(error)")
            return
        }
        defer { Task { await client.close() } }

        var outcome: DecodingOutcome = .completed
        do {
            _ = try await client.selectAll(
                "SELECT 'x' AS v",
                as: WrongKeyRow.self
            )
        } catch let error {
            outcome = Self.classify(error)
        }
        switch outcome {
        case .protocolError, .queryFailed:
            break
        case .completed:
            Issue.record("expected decoding to fail when row key does not match column name")
        case .other(let description):
            Issue.record("unexpected error: \(description)")
        }
    }

    @Test("scalar with a wrong type throws a typed error")
    func scalarWithWrongTypeThrows() async {
        let client: ClickHouseClient
        do {
            client = try await Self.makeClient()
        } catch {
            Issue.record("could not connect: \(error)")
            return
        }
        defer { Task { await client.close() } }

        var outcome: DecodingOutcome = .completed
        do {
            _ = try await client.scalar("SELECT 'not-a-number'", as: UInt64.self)
        } catch let error {
            outcome = Self.classify(error)
        }
        switch outcome {
        case .protocolError, .queryFailed:
            break
        case .completed:
            Issue.record("expected decoding to fail on type mismatch")
        case .other(let description):
            Issue.record("unexpected error: \(description)")
        }
    }

    @Test("INSERT into a column with wrong name surfaces a typed error")
    func insertSchemaMismatchSurfacesProtocolError() async {
        let client: ClickHouseClient
        do {
            client = try await Self.makeClient()
        } catch {
            Issue.record("could not connect: \(error)")
            return
        }
        defer { Task { await client.close() } }

        let table = "malformed_schema_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        try? await client.execute("DROP TABLE IF EXISTS \(table)")
        try? await client.execute("CREATE TABLE \(table) (a UInt64) ENGINE = Memory")

        var outcome: DecodingOutcome = .completed
        do {
            _ = try await client.insert(into: table, rows: [StringRow(v: "x")])
        } catch let error {
            outcome = Self.classify(error)
        }
        switch outcome {
        case .protocolError, .queryFailed:
            break
        case .completed:
            Issue.record("expected schema mismatch to throw")
        case .other(let description):
            Issue.record("unexpected error: \(description)")
        }
        try? await client.execute("DROP TABLE IF EXISTS \(table)")
    }

    @Test("INSERT into a nonexistent table surfaces .queryFailed")
    func insertIntoMissingTableSurfacesQueryFailed() async {
        let client: ClickHouseClient
        do {
            client = try await Self.makeClient()
        } catch {
            Issue.record("could not connect: \(error)")
            return
        }
        defer { Task { await client.close() } }

        struct UInt8Row: Codable, Sendable { let v: UInt8 }
        var outcome: DecodingOutcome = .completed
        do {
            _ = try await client.insert(
                into: "this_table_definitely_does_not_exist_xyz_swiftdx",
                rows: [UInt8Row(v: 1)]
            )
        } catch let error {
            outcome = Self.classify(error)
        }
        switch outcome {
        case .queryFailed(let code):
            #expect(code != 0)
        case .protocolError:
            break
        case .completed:
            Issue.record("expected insert into missing table to throw")
        case .other(let description):
            Issue.record("unexpected error: \(description)")
        }
    }

    @Test("SELECT with a type narrower than data surfaces a typed error")
    func selectWithNarrowerTypeThrows() async {
        let client: ClickHouseClient
        do {
            client = try await Self.makeClient()
        } catch {
            Issue.record("could not connect: \(error)")
            return
        }
        defer { Task { await client.close() } }

        var outcome: DecodingOutcome = .completed
        do {
            _ = try await client.selectAll(
                "SELECT toUInt64(1000) AS v",
                as: WrongTypeRow.self
            )
        } catch let error {
            outcome = Self.classify(error)
        }
        switch outcome {
        case .protocolError, .queryFailed:
            break
        case .completed:
            Issue.record("expected type-mismatch decoding to fail")
        case .other(let description):
            Issue.record("unexpected error: \(description)")
        }
    }
}
