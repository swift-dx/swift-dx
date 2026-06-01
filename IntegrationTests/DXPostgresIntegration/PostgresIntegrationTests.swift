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

@Suite(.enabled(if: PostgresIntegration.isEnabled)) struct PostgresIntegrationTests {

    @Test func connectsAndPings() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            try await postgres.ping()
        }
    }

    @Test func runsSimpleSelectAndDecodesColumns() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let result = try await postgres.query("SELECT 7 AS number, 'swift'::text AS word, true AS flag")
            #expect(result.rowCount == 1)
            let row = result.rows[0]
            #expect(try row.decode(Int.self, named: "number") == 7)
            #expect(try row.decode(String.self, named: "word") == "swift")
            #expect(try row.decode(Bool.self, named: "flag") == true)
        }
    }

    @Test func runsParameterizedQuery() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let result = try await postgres.query(
                "SELECT $1::int + $2::int AS total, $3::text AS label",
                binding: [40, 2, "answer"]
            )
            let row = result.rows[0]
            #expect(try row.decode(Int.self, named: "total") == 42)
            #expect(try row.decode(String.self, named: "label") == "answer")
        }
    }

    @Test func decodesNullAndPresentValuesInOneRow() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let result = try await postgres.query("SELECT NULL::text AS absent, 'present'::text AS here")
            let row = result.rows[0]
            #expect(try row.decodeNullable(String.self, named: "absent") == .sqlNull)
            #expect(try row.decodeNullable(String.self, named: "here") == .value("present"))
        }
    }

    @Test func roundTripsThroughATemporaryTable() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let table = "dxpg_test_\(UInt32.random(in: 0...UInt32.max))"
            _ = try await postgres.query("CREATE TEMP TABLE \(table) (id int primary key, name text)")
            let inserted = try await postgres.query("INSERT INTO \(table) (id, name) VALUES ($1, $2), ($3, $4)", binding: [1, "ada", 2, "alan"])
            #expect(inserted.commandTag.affectedRows == 2)
            let selected = try await postgres.query("SELECT id, name FROM \(table) ORDER BY id")
            #expect(selected.rowCount == 2)
            #expect(try selected.rows[1].decode(String.self, named: "name") == "alan")
        }
    }

    @Test func surfacesServerErrorWithSqlState() async throws {
        await #expect(throws: PostgresError.self) {
            try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
                _ = try await postgres.query("SELECT * FROM a_table_that_does_not_exist")
            }
        }
    }

    @Test func runsConcurrentQueriesAcrossThePool() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration(maxConnections: 4)) { postgres in
            try await withThrowingTaskGroup(of: Int.self) { group in
                for value in 0..<16 {
                    group.addTask {
                        let result = try await postgres.query("SELECT \(value)::int AS v")
                        return try result.rows[0].decode(Int.self, named: "v")
                    }
                }
                var sum = 0
                for try await value in group {
                    sum += value
                }
                #expect(sum == (0..<16).reduce(0, +))
            }
        }
    }
}
