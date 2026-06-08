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

// A typed query reused on the same pooled connection must decode against the
// column metadata of the statement that produced the rows. The extended-protocol
// path caches the parsed statement per connection; on reuse the server sends no
// RowDescription unless the bound portal is described every execution. Without
// that describe the second run sees empty column metadata: zero rows decode
// silently to an empty array, and any row fails every column-name lookup. These
// tests reproduce both shapes against a real server.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PG_INTEGRATION_HOST"] != nil))
struct PreparedStatementMetadataTest {

    private static var host: String { ProcessInfo.processInfo.environment["PG_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["PG_INTEGRATION_PORT"] ?? "5432") ?? 5432 }
    private static var username: String { ProcessInfo.processInfo.environment["PG_INTEGRATION_USER"] ?? "postgres" }
    private static var password: String { ProcessInfo.processInfo.environment["PG_INTEGRATION_PASSWORD"] ?? "" }
    private static var database: String { ProcessInfo.processInfo.environment["PG_INTEGRATION_DATABASE"] ?? "postgres" }

    private struct Pair: Decodable, Sendable, Equatable {

        let a: Int
        let b: String
    }

    private static func withClient<Result: Sendable>(_ body: (any PostgresClient) async throws -> Result) async throws -> Result {
        try await Postgres.withClient(
            host: host, port: port, username: username, password: password, database: database,
            applicationName: "dxpg-integration", searchPath: .serverDefault, poolSize: 1, maxSubscriptions: 1, body
        )
    }

    private static let expected = [Pair(a: 1, b: "one"), Pair(a: 2, b: "two")]

    @Test("typed query decodes correctly when reused on a cached statement", .timeLimit(.minutes(1)))
    func reusedTypedQueryDecodes() async throws {
        try await Self.withClient { client in
            let table = "dx_meta_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
            _ = try await client.execute("CREATE TABLE \(table) (a int, b text)")
            _ = try await client.execute("INSERT INTO \(table) VALUES (1, 'one'), (2, 'two')")

            let statement: PostgresStatement = "SELECT a, b FROM \(identifier: table) ORDER BY a"
            let first = try await client.query(statement, as: Pair.self)
            #expect(first == Self.expected)

            let second = try await client.query(statement, as: Pair.self)
            #expect(second == Self.expected)

            let third = try await client.query(statement, as: Pair.self)
            #expect(third == Self.expected)

            _ = try await client.execute("DROP TABLE \(table)")
        }
    }

    @Test("execute then typed query in one transaction decodes correctly on reuse", .timeLimit(.minutes(1)))
    func executeThenTypedQueryInTransaction() async throws {
        try await Self.withClient { client in
            let table = "dx_metatx_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
            _ = try await client.execute("CREATE TABLE \(table) (a int, b text)")
            _ = try await client.execute("INSERT INTO \(table) VALUES (1, 'one'), (2, 'two')")

            for _ in 0..<3 {
                let rows = try await client.transaction { transaction in
                    _ = try transaction.execute("SET LOCAL statement_timeout = 0")
                    let statement: PostgresStatement = "SELECT a, b FROM \(identifier: table) ORDER BY a"
                    return try transaction.query(statement, as: Pair.self)
                }
                #expect(rows == Self.expected)
            }

            _ = try await client.execute("DROP TABLE \(table)")
        }
    }
}
