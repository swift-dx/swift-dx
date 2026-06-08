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

import DXPostgres
import Foundation
import Testing

// A connection opened with an explicit search path resolves unqualified names
// against the listed schemas, set once in the startup packet, so no per-query
// qualification or per-transaction SET is needed. This verifies the startup
// search_path against a real server: a table living only in a non-default schema
// is reachable unqualified when that schema is on the path, and is not reachable
// when the path is left at the server default.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PG_INTEGRATION_HOST"] != nil))
struct SearchPathIntegrationTest {

    private static var host: String { ProcessInfo.processInfo.environment["PG_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["PG_INTEGRATION_PORT"] ?? "5432") ?? 5432 }
    private static var username: String { ProcessInfo.processInfo.environment["PG_INTEGRATION_USER"] ?? "postgres" }
    private static var password: String { ProcessInfo.processInfo.environment["PG_INTEGRATION_PASSWORD"] ?? "" }
    private static var database: String { ProcessInfo.processInfo.environment["PG_INTEGRATION_DATABASE"] ?? "postgres" }

    private struct Row: Decodable, Sendable, Equatable {

        let id: Int
    }

    private static func withClient<Result: Sendable>(searchPath: PostgresSearchPath, _ body: (any PostgresClient) async throws -> Result) async throws -> Result {
        try await Postgres.withClient(
            host: host, port: port, username: username, password: password, database: database,
            applicationName: "dxpg-searchpath", searchPath: searchPath, poolSize: 1, maxSubscriptions: 1, body
        )
    }

    @Test("startup search_path makes a non-default schema reachable unqualified", .timeLimit(.minutes(1)))
    func searchPathResolvesUnqualifiedNames() async throws {
        let schema = "dx_sp_\(Int(Date().timeIntervalSince1970 * 1_000_000))"

        try await Self.withClient(searchPath: .serverDefault) { client in
            _ = try await client.execute("CREATE SCHEMA \(schema)")
            _ = try await client.execute("CREATE TABLE \(schema).widget (id int)")
            _ = try await client.execute("INSERT INTO \(schema).widget VALUES (7)")
        }

        try await Self.withClient(searchPath: .schemas([schema, "public"])) { client in
            let rows = try await client.query("SELECT id FROM widget", as: Row.self)
            #expect(rows == [Row(id: 7)])
        }

        try await Self.withClient(searchPath: .serverDefault) { client in
            let resolvedWithoutPath = try? await client.query("SELECT id FROM widget", as: Row.self)
            #expect(resolvedWithoutPath == nil)
            _ = try await client.execute("DROP SCHEMA \(schema) CASCADE")
        }
    }
}
