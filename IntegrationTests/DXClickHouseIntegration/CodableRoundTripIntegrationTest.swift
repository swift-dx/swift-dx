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

// Live-broker integration cover for the typed Codable layer:
//
//   * ClickHouseClient.insert<T>(into:rows:)
//   * ClickHouseClient.select<T>(_:as:settings:parameters:)
//   * ClickHouseClient.scalar<T>(_:as:)
//
// Round-trips a struct through INSERT → SELECT against a live broker
// to confirm the encoder, the block writer, the inbound block parser,
// and the columnar decoder all agree on the wire layout. Gated on
// CH_INTEGRATION_HOST so it only runs when a broker is wired.
@Suite(
    "DXClickHouse Codable round-trip integration",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseCodableRoundTripIntegration {

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

    struct OrderRow: Codable, Sendable, Equatable {
        let id: UInt64
        let buyer: String
        let amount: Double
        let active: Bool
    }

    struct OptionalRow: Codable, Sendable, Equatable {
        let id: UInt64
        let comment: String?
        let bonus: Int32?
    }

    @Test("Codable insert + select round-trips a scalar struct through ClickHouse")
    func roundTripsScalarStruct() async throws {
        let table = "dx_raw_codable_rt_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await Self.runDDL(client: client, "DROP TABLE IF EXISTS \(table)")
        try await Self.runDDL(client: client, """
            CREATE TABLE \(table) (
                id UInt64,
                buyer String,
                amount Float64,
                active Bool
            ) ENGINE = Memory
            """)
        let rows = [
            OrderRow(id: 1, buyer: "alice", amount: 19.99, active: true),
            OrderRow(id: 2, buyer: "bob", amount: 42.5, active: false),
            OrderRow(id: 3, buyer: "carol with spaces", amount: 0, active: true),
        ]
        let summary = try await client.insert(into: table, rows: rows)
        #expect(summary.rowsSent == 3)
        #expect(summary.blocksSent == 1)

        var fetched: [OrderRow] = []
        for try await row in client.select("SELECT id, buyer, amount, active FROM \(table) ORDER BY id", as: OrderRow.self) {
            fetched.append(row)
        }
        #expect(fetched == rows)

        try await Self.runDDL(client: client, "DROP TABLE \(table)")
    }

    @Test("Codable insert + select round-trips Nullable columns")
    func roundTripsNullableColumns() async throws {
        let table = "dx_raw_codable_nullable_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await Self.runDDL(client: client, "DROP TABLE IF EXISTS \(table)")
        try await Self.runDDL(client: client, """
            CREATE TABLE \(table) (
                id UInt64,
                comment Nullable(String),
                bonus Nullable(Int32)
            ) ENGINE = Memory
            """)
        let rows = [
            OptionalRow(id: 1, comment: "first", bonus: 100),
            OptionalRow(id: 2, comment: nil, bonus: nil),
            OptionalRow(id: 3, comment: "third", bonus: -10),
        ]
        let summary = try await client.insert(into: table, rows: rows)
        #expect(summary.rowsSent == 3)

        var fetched: [OptionalRow] = []
        for try await row in client.select("SELECT id, comment, bonus FROM \(table) ORDER BY id", as: OptionalRow.self) {
            fetched.append(row)
        }
        #expect(fetched == rows)

        try await Self.runDDL(client: client, "DROP TABLE \(table)")
    }

    @Test("scalar<UInt64> decodes a single-cell SELECT count() result")
    func scalarUInt64Count() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let count = try await client.scalar("SELECT toUInt64(count()) FROM numbers(1000)", as: UInt64.self)
        #expect(count == 1000)
    }

    @Test("scalar<String> returns a literal string")
    func scalarString() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let greeting = try await client.scalar("SELECT 'hello world'", as: String.self)
        #expect(greeting == "hello world")
    }

    @Test("scalar throws .protocolError when result has more than one row")
    func scalarRejectsMultipleRows() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let caught = await captureClientError {
            _ = try await client.scalar("SELECT toUInt64(number) FROM numbers(3)", as: UInt64.self)
        }
        switch caught {
        case .some(let error):
            switch error {
            case .protocolError: break
            default:
                Issue.record("expected protocolError, got \(error)")
            }
        case .none:
            Issue.record("expected scalar to reject multi-row result")
        }
    }

    @Test("Insert against unknown table surfaces a typed queryFailed exception")
    func insertUnknownTableSurfacesQueryFailed() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let row = OrderRow(id: 1, buyer: "x", amount: 1.0, active: true)
        let caught = await captureClientError {
            _ = try await client.insert(into: "definitely_not_a_real_table_xyz", rows: [row])
        }
        switch caught {
        case .some(let error):
            switch error {
            case .queryFailed(let exception):
                #expect(exception.code != 0)
            default:
                Issue.record("expected queryFailed, got \(error)")
            }
        case .none:
            Issue.record("expected insert into unknown table to fail")
        }
    }

    @Test("Select against unknown table surfaces a typed queryFailed exception")
    func selectUnknownTableSurfacesQueryFailed() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let caught: ClickHouseError? = await captureClientError {
            for try await _ in client.select("SELECT * FROM definitely_not_a_real_table_xyz", as: OrderRow.self) { }
        }
        switch caught {
        case .some(let error):
            switch error {
            case .queryFailed: break
            default: Issue.record("expected queryFailed, got \(error)")
            }
        case .none:
            Issue.record("expected select on unknown table to fail")
        }
    }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(
            host: host, port: port,
            user: user, password: password, database: database
        )
    }

    // DDL statements return no rows. The typed client surface rejects
    // 0-row scalar results and the streaming select<T> path expects
    // typed rows. Drive DDL through a fresh sync connection so the
    // EndOfStream drain happens via the existing receiveBlocks path.
    private static func runDDL(client: ClickHouseClient, _ sql: String) async throws {
        let conn = try ClickHouseConnection(
            host: host, port: port,
            user: user, password: password, database: database
        )
        defer { conn.close() }
        try conn.sendQuery(sql)
        _ = try conn.receiveBlocks { _, _ in }
    }
}

private func captureClientError(_ body: () async throws -> Void) async -> ClickHouseError? {
    do {
        try await body()
        return nil
    } catch let error as ClickHouseError {
        return error
    } catch {
        return nil
    }
}
