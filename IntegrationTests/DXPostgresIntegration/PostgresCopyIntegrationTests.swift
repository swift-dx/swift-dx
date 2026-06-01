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

@Suite(.enabled(if: PostgresIntegration.isEnabled)) struct PostgresCopyIntegrationTests {

    private func uniqueTable() -> String {
        "dxpg_copy_\(UInt32.random(in: 0...UInt32.max))"
    }

    @Test func bulkLoadsRows() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let table = uniqueTable()
            _ = try await postgres.query("CREATE TABLE \(table) (id int8, name text, amount numeric)")
            let rows: [[any PostgresEncodable]] = (1...2000).map { [Int64($0), "name-\($0)", Decimal($0)] }
            let loaded = try await postgres.copyIn(into: table, columns: ["id", "name", "amount"], rows: rows)
            #expect(loaded == 2000)
            let count = try await postgres.query("SELECT count(*)::int8 AS n, max(id)::int8 AS top FROM \(table)").rows[0]
            #expect(try count.decode(Int64.self, named: "n") == 2000)
            #expect(try count.decode(Int64.self, named: "top") == 2000)
            _ = try await postgres.query("DROP TABLE \(table)")
        }
    }

    @Test func escapesNullsAndSpecialCharacters() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let table = uniqueTable()
            _ = try await postgres.query("CREATE TABLE \(table) (id int8, label text)")
            let tricky = "tab\tnewline\nbackslash\\end"
            let rows: [[any PostgresEncodable]] = [
                [Int64(1), tricky],
                [Int64(2), PostgresNull()],
            ]
            let loaded = try await postgres.copyIn(into: table, columns: ["id", "label"], rows: rows)
            #expect(loaded == 2)
            let first = try await postgres.query("SELECT label FROM \(table) WHERE id = 1").rows[0]
            #expect(try first.decode(String.self, named: "label") == tricky)
            let second = try await postgres.query("SELECT label FROM \(table) WHERE id = 2").rows[0]
            #expect(try second.decodeNullable(String.self, named: "label") == .sqlNull)
            _ = try await postgres.query("DROP TABLE \(table)")
        }
    }

    @Test func reportsServerErrorOnInvalidData() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let table = uniqueTable()
            _ = try await postgres.query("CREATE TABLE \(table) (id int8)")
            let rows: [[any PostgresEncodable]] = [[Int64(1)], ["not-an-integer"]]
            await #expect(throws: PostgresError.self) {
                _ = try await postgres.copyIn(into: table, columns: ["id"], rows: rows)
            }
            let recovered = try await postgres.query("SELECT 1 AS ok").rows[0]
            #expect(try recovered.decode(Int.self, named: "ok") == 1)
            _ = try await postgres.query("DROP TABLE \(table)")
        }
    }
}
