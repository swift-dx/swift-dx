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

@Suite(.enabled(if: PostgresIntegration.isEnabled)) struct PostgresDurabilityIntegrationTests {

    private func uniqueTable() -> String {
        "dxpg_dur_\(UInt32.random(in: 0...UInt32.max))"
    }

    // A single write at a chosen durability persists and reports success only on
    // server confirmation. synchronous_commit=off relaxes the crash window, not the
    // acknowledgement: the row is present once execute returns.
    @Test func asynchronousSingleWritePersists() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration(maxConnections: 1)) { postgres in
            let table = uniqueTable()
            _ = try await postgres.query("CREATE TABLE \(table) (id int primary key, label text)")
            _ = try await postgres.execute("INSERT INTO \(table) (id, label) VALUES ($1, $2)", binding: [1, "async"], durability: .asynchronous)
            let row = try await postgres.query("SELECT label FROM \(table) WHERE id = 1").rows[0]
            #expect(try row.decode(String.self, named: "label") == "async")
            _ = try await postgres.query("DROP TABLE \(table)")
        }
    }

    // The level is actually applied to the transaction: SHOW inside the body
    // reflects the requested synchronous_commit value.
    @Test func transactionAppliesRequestedDurabilityLevel() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration(maxConnections: 1)) { postgres in
            let observed = try await postgres.withTransaction(durability: .asynchronous) { transaction -> String in
                let row = try await transaction.query("SHOW synchronous_commit").rows[0]
                return try row.decode(String.self, named: "synchronous_commit")
            }
            #expect(observed == "off")
            let observedSync = try await postgres.withTransaction(durability: .synchronous) { transaction -> String in
                let row = try await transaction.query("SHOW synchronous_commit").rows[0]
                return try row.decode(String.self, named: "synchronous_commit")
            }
            #expect(observedSync == "on")
        }
    }

    // SET LOCAL scopes to the transaction, so the pooled connection does not leak
    // the relaxed level to a later caller: a plain query after the transaction sees
    // the session default again, even on a single-connection pool that reuses the
    // same physical connection.
    @Test func durabilityDoesNotLeakToNextStatement() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration(maxConnections: 1)) { postgres in
            let sessionDefault = try await postgres.query("SHOW synchronous_commit").rows[0]
            let before = try sessionDefault.decode(String.self, named: "synchronous_commit")
            _ = try await postgres.withTransaction(durability: .asynchronous) { transaction in
                _ = try await transaction.query("SELECT 1")
            }
            let after = try await postgres.query("SHOW synchronous_commit").rows[0]
            #expect(try after.decode(String.self, named: "synchronous_commit") == before)
        }
    }
}
