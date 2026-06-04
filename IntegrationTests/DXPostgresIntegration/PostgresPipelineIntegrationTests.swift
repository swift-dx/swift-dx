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

@Suite(.enabled(if: PostgresIntegration.isEnabled)) struct PostgresPipelineIntegrationTests {

    private func uniqueTable() -> String {
        "dxpg_pipe_\(UInt32.random(in: 0...UInt32.max))"
    }

    // The whole batch is sent in one round-trip and every row persists, in order,
    // with one result per parameter set.
    @Test func pipelineInsertsEveryRow() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration(maxConnections: 1)) { postgres in
            let table = uniqueTable()
            _ = try await postgres.query("CREATE TABLE \(table) (id int primary key, label text)")
            try await postgres.withConnection { session in
                let bindings: [[any PostgresEncodable]] = (1...500).map { [$0, "row-\($0)"] }
                let results = try await session.pipeline("INSERT INTO \(table) (id, label) VALUES ($1, $2)", bindings: bindings)
                #expect(results.count == 500)
                #expect(results.allSatisfy { $0.commandTag.affectedRows == 1 })
            }
            let count = try await postgres.query("SELECT count(*)::int8 AS n FROM \(table)").rows[0]
            #expect(try count.decode(Int64.self, named: "n") == 500)
            _ = try await postgres.query("DROP TABLE \(table)")
        }
    }

    // A select pipeline returns each set's rows in order.
    @Test func pipelineSelectsReturnRowsPerSet() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration(maxConnections: 1)) { postgres in
            try await postgres.withConnection { session in
                let bindings: [[any PostgresEncodable]] = (1...50).map { [Int64($0)] }
                let results = try await session.pipeline("SELECT $1::int8 AS n", bindings: bindings)
                #expect(results.count == 50)
                let first = try results[0].rows[0].decode(Int64.self, named: "n")
                let last = try results[49].rows[0].decode(Int64.self, named: "n")
                #expect(first == 1)
                #expect(last == 50)
            }
        }
    }

    // A failure in one statement is isolated: the rest of the batch still applies,
    // the batch surfaces the error, and the connection stays usable afterward.
    @Test func pipelineErrorIsolatesAndConnectionRecovers() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration(maxConnections: 1)) { postgres in
            let table = uniqueTable()
            _ = try await postgres.query("CREATE TABLE \(table) (id int primary key)")
            _ = try await postgres.query("INSERT INTO \(table) (id) VALUES (2)")
            await #expect(throws: PostgresError.self) {
                try await postgres.withConnection { session in
                    // ids 1 and 3 succeed; id 2 collides with the existing row.
                    let bindings: [[any PostgresEncodable]] = [[1], [2], [3]]
                    _ = try await session.pipeline("INSERT INTO \(table) (id) VALUES ($1)", bindings: bindings)
                }
            }
            let count = try await postgres.query("SELECT count(*)::int8 AS n FROM \(table)").rows[0]
            #expect(try count.decode(Int64.self, named: "n") == 3)
            let recovered = try await postgres.query("SELECT 1 AS ok").rows[0]
            #expect(try recovered.decode(Int.self, named: "ok") == 1)
            _ = try await postgres.query("DROP TABLE \(table)")
        }
    }
}
