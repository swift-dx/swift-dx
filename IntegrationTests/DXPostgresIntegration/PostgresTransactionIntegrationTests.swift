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

@Suite(.enabled(if: PostgresIntegration.isEnabled)) struct PostgresTransactionIntegrationTests {

    private struct RolledBack: Error {}

    private func uniqueTable() -> String {
        "dxpg_tx_\(UInt32.random(in: 0...UInt32.max))"
    }

    @Test func commitPersistsAllWrites() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration(maxConnections: 1)) { postgres in
            let table = uniqueTable()
            _ = try await postgres.query("CREATE TABLE \(table) (id int primary key)")
            try await postgres.withTransaction { transaction in
                for value in 1...5 {
                    _ = try await transaction.query("INSERT INTO \(table) (id) VALUES ($1)", binding: [value])
                }
            }
            let count = try await postgres.query("SELECT count(*)::int8 AS n FROM \(table)").rows[0]
            #expect(try count.decode(Int64.self, named: "n") == 5)
            _ = try await postgres.query("DROP TABLE \(table)")
        }
    }

    @Test func rollbackDiscardsWritesWhenBodyThrows() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration(maxConnections: 1)) { postgres in
            let table = uniqueTable()
            _ = try await postgres.query("CREATE TABLE \(table) (id int primary key)")
            await #expect(throws: RolledBack.self) {
                try await postgres.withTransaction { transaction in
                    _ = try await transaction.query("INSERT INTO \(table) (id) VALUES (1)")
                    throw RolledBack()
                }
            }
            let count = try await postgres.query("SELECT count(*)::int8 AS n FROM \(table)").rows[0]
            #expect(try count.decode(Int64.self, named: "n") == 0)
            _ = try await postgres.query("DROP TABLE \(table)")
        }
    }

    @Test func serverErrorInTransactionRollsBackAndConnectionRecovers() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration(maxConnections: 1)) { postgres in
            let table = uniqueTable()
            _ = try await postgres.query("CREATE TABLE \(table) (id int primary key)")
            await #expect(throws: PostgresError.self) {
                try await postgres.withTransaction { transaction in
                    _ = try await transaction.query("INSERT INTO \(table) (id) VALUES (1)")
                    _ = try await transaction.query("INSERT INTO \(table) (id) VALUES (1)")
                }
            }
            let recovered = try await postgres.query("SELECT 1 AS ok").rows[0]
            #expect(try recovered.decode(Int.self, named: "ok") == 1)
            _ = try await postgres.query("DROP TABLE \(table)")
        }
    }

    // A bulk insert wrapped in a single transaction persists every row atomically.
    // (The performance advantage over autocommit is measured by the benchmark; this
    // is a portable correctness check that avoids TRUNCATE, which on YugabyteDB
    // replaces the table object and would invalidate a cached prepared statement.)
    @Test func transactionalBulkInsertPersistsEveryRow() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration(maxConnections: 1)) { postgres in
            let table = uniqueTable()
            _ = try await postgres.query("CREATE TABLE \(table) (id int primary key)")
            let rows = 500
            try await postgres.withTransaction { transaction in
                for value in 0..<rows {
                    _ = try await transaction.query("INSERT INTO \(table) (id) VALUES ($1)", binding: [value])
                }
            }
            let count = try await postgres.query("SELECT count(*)::int8 AS n FROM \(table)").rows[0]
            #expect(try count.decode(Int64.self, named: "n") == Int64(rows))
            _ = try await postgres.query("DROP TABLE \(table)")
        }
    }
}
