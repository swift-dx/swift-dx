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

// The full jsonb workflow: store a Codable value as jsonb, index it, query by a
// scalar field (->>), query by containment (@>), and decode the document back.
// Query-by-field works on both PostgreSQL and YugabyteDB; the GIN index is created
// best-effort because its support differs across servers.
@Suite(.enabled(if: PostgresIntegration.isEnabled)) struct PostgresJSONWorkflowIntegrationTests {

    private struct Account: Codable, Equatable, Sendable {
        let name: String
        let tier: String
        let active: Bool
    }

    @Test func storeIndexAndQueryByJSONField() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let table = "dxpg_json_\(UInt32.random(in: 0...UInt32.max))"
            _ = try await postgres.query("CREATE TABLE \(table) (id int primary key, body jsonb)")
            _ = try? await postgres.query("CREATE INDEX ON \(table) USING gin (body)")

            let accounts = [
                Account(name: "ada", tier: "gold", active: true),
                Account(name: "alan", tier: "silver", active: false),
                Account(name: "grace", tier: "gold", active: true),
            ]
            for (offset, account) in accounts.enumerated() {
                _ = try await postgres.query("INSERT INTO \(table) (id, body) VALUES ($1, $2)", binding: [offset, PostgresJSON(account)])
            }

            // Query by a scalar JSON field with ->>.
            let goldByField = try await postgres.query("SELECT id FROM \(table) WHERE body->>'tier' = $1 ORDER BY id", binding: ["gold"])
            #expect(goldByField.rowCount == 2)
            #expect(try goldByField.rows[0].decode(Int.self, named: "id") == 0)

            // Query by containment with @> and decode the document back.
            let activeGold = try await postgres.query("SELECT body FROM \(table) WHERE body @> '{\"tier\":\"gold\",\"active\":true}' ORDER BY id")
            #expect(activeGold.rowCount == 2)
            #expect(try activeGold.rows[0].decodeJSON(Account.self, named: "body") == accounts[0])

            // Extract a nested scalar field as text.
            let name = try await postgres.query("SELECT body->>'name' AS n FROM \(table) WHERE id = $1", binding: [2]).rows[0]
            #expect(try name.decode(String.self, named: "n") == "grace")

            _ = try await postgres.query("DROP TABLE \(table)")
        }
    }
}
