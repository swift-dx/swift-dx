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

import Foundation
import Testing
import DXSQLite

@Suite("DXSQLite virtual tables")
struct SQLiteVirtualTableTests {

    @Test("a static virtual table is queryable by name with ordering and filtering")
    func staticTableQuery() async throws {
        let path = NSTemporaryDirectory() + "dxsqlite-vtab-\(UUID().uuidString).sqlite"
        let provider = SQLiteStaticTable(
            name: "planets",
            columns: ["id", "label", "mass"],
            rows: [
                [.integer(1), .text("Mercury"), .real(3.30)],
                [.integer(2), .text("Venus"), .real(4.87)],
                [.integer(3), .text("Earth"), .real(5.97)],
            ]
        )
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), virtualTables: [provider]))

        let labels = try await database.read { reader in
            try reader.query("SELECT label FROM planets ORDER BY mass DESC")
        }
        #expect(labels.count == 3)
        #expect(try labels[0].text(named: "label") == "Earth")
        #expect(try labels[2].text(named: "label") == "Mercury")

        let earth = try await database.read { reader in
            try reader.query("SELECT id, label FROM planets WHERE label = 'Earth'")
        }
        #expect(earth.count == 1)
        #expect(try earth[0].integer(named: "id") == 3)

        let total = try await database.read { reader in
            try reader.query("SELECT COUNT(*) AS n FROM planets")
        }
        #expect(try total[0].integer(named: "n") == 3)

        await database.close()
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    @Test("the same virtual table is visible to a join against a real table")
    func virtualTableJoinsRealTable() async throws {
        let path = NSTemporaryDirectory() + "dxsqlite-vtab-join-\(UUID().uuidString).sqlite"
        let provider = SQLiteStaticTable(
            name: "rates",
            columns: ["code", "factor"],
            rows: [
                [.text("USD"), .real(1.0)],
                [.text("EUR"), .real(1.08)],
            ]
        )
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), virtualTables: [provider]))

        try await database.write { writer in
            try writer.execute("CREATE TABLE invoice (id INTEGER PRIMARY KEY, currency TEXT, amount REAL)")
            _ = try writer.mutate("INSERT INTO invoice (id, currency, amount) VALUES (1, 'EUR', 50.0)", parameters: [])
        }

        let converted = try await database.read { reader in
            try reader.query("SELECT invoice.amount * rates.factor AS total FROM invoice JOIN rates ON invoice.currency = rates.code")
        }
        #expect(converted.count == 1)
        #expect(try converted[0].double(named: "total") == 54.0)

        await database.close()
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }
}
