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

@Suite("DXSQLite schema migration")
struct SQLiteSchemaMigrationTests {

    static let tempPrefix = "dxsqlite-migrate"

    static func makePath() -> String {
        NSTemporaryDirectory() + "\(tempPrefix)-\(UUID().uuidString).sqlite"
    }

    static func removeFiles(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    static func seedOrders(_ database: SQLiteDatabase, rowCount: Int) async throws {
        try await database.write { writer in
            try writer.execute("CREATE TABLE orders (id INTEGER PRIMARY KEY, reference TEXT NOT NULL, amount REAL NOT NULL)")
            for index in 0..<rowCount {
                _ = try writer.mutate(
                    "INSERT INTO orders(id, reference, amount) VALUES (?, ?, ?)",
                    parameters: [.integer(Int64(index + 1)), .text("REF-\(index + 1)"), .real(Double(index + 1) * 2.0)]
                )
            }
        }
    }

    static func countRows(_ database: SQLiteDatabase, table: String) async throws -> Int {
        try await database.read { reader in
            let rows = try reader.query("SELECT COUNT(*) AS total FROM \(table)")
            let total = try rows[0].integer(named: "total")
            return Int(total)
        }
    }

    static func columnNames(_ database: SQLiteDatabase, table: String) async throws -> [String] {
        try await database.read { reader in
            let rows = try reader.query("PRAGMA table_info(\(table))")
            var names: [String] = []
            for row in rows {
                let name = try row.text(named: "name")
                names.append(name)
            }
            return names
        }
    }

    @Test("add column with a default backfills existing rows and accepts new values")
    func addColumnWithDefaultBackfillsAndAcceptsNewRows() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await Self.seedOrders(database, rowCount: 300)

        try await database.write { writer in
            try writer.execute("ALTER TABLE orders ADD COLUMN status TEXT NOT NULL DEFAULT 'pending'")
        }

        let pendingCount = try await database.read { reader in
            let rows = try reader.query("SELECT COUNT(*) AS total FROM orders WHERE status = ?", parameters: [.text("pending")])
            let total = try rows[0].integer(named: "total")
            return Int(total)
        }
        #expect(pendingCount == 300)

        try await database.write { writer in
            _ = try writer.mutate(
                "INSERT INTO orders(id, reference, amount, status) VALUES (?, ?, ?, ?)",
                parameters: [.integer(301), .text("REF-301"), .real(900.0), .text("shipped")]
            )
        }

        let shippedReference = try await database.read { reader in
            let rows = try reader.query("SELECT reference FROM orders WHERE status = ?", parameters: [.text("shipped")])
            #expect(rows.count == 1)
            return try rows[0].text(named: "reference")
        }
        #expect(shippedReference == "REF-301")

        let totalRows = try await Self.countRows(database, table: "orders")
        #expect(totalRows == 301)

        await database.close()
        Self.removeFiles(path)
    }

    @Test("creating an index on a populated table serves correct lookups and repeats safely")
    func createIndexServesLookupsAndIsIdempotent() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await Self.seedOrders(database, rowCount: 250)

        try await database.write { writer in
            try writer.execute("CREATE INDEX idx_orders_reference ON orders(reference)")
        }

        let amount = try await database.read { reader in
            let rows = try reader.query("SELECT amount FROM orders WHERE reference = ?", parameters: [.text("REF-125")])
            #expect(rows.count == 1)
            return try rows[0].double(named: "amount")
        }
        #expect(amount == 250.0)

        try await database.write { writer in
            try writer.execute("CREATE INDEX IF NOT EXISTS idx_orders_reference ON orders(reference)")
        }

        let indexCount = try await database.read { reader in
            let rows = try reader.query("SELECT COUNT(*) AS total FROM sqlite_master WHERE type = 'index' AND name = ?", parameters: [.text("idx_orders_reference")])
            let total = try rows[0].integer(named: "total")
            return Int(total)
        }
        #expect(indexCount == 1)

        let stillCorrect = try await database.read { reader in
            let rows = try reader.query("SELECT reference FROM orders WHERE reference = ?", parameters: [.text("REF-200")])
            #expect(rows.count == 1)
            return try rows[0].text(named: "reference")
        }
        #expect(stillCorrect == "REF-200")

        await database.close()
        Self.removeFiles(path)
    }

    @Test("a multi-step migration in one transaction commits the whole end state atomically")
    func multiStepMigrationCommitsAtomically() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await Self.seedOrders(database, rowCount: 200)

        try await database.transaction { writer in
            try writer.execute("ALTER TABLE orders ADD COLUMN tier TEXT NOT NULL DEFAULT 'standard'")
            _ = try writer.mutate("UPDATE orders SET tier = ? WHERE amount >= ?", parameters: [.text("premium"), .real(200.0)])
            try writer.execute("CREATE INDEX idx_orders_tier ON orders(tier)")
        }

        let columns = try await Self.columnNames(database, table: "orders")
        #expect(columns.contains("tier"))

        let premiumCount = try await database.read { reader in
            let rows = try reader.query("SELECT COUNT(*) AS total FROM orders WHERE tier = ?", parameters: [.text("premium")])
            let total = try rows[0].integer(named: "total")
            return Int(total)
        }
        #expect(premiumCount == 101)

        let standardCount = try await database.read { reader in
            let rows = try reader.query("SELECT COUNT(*) AS total FROM orders WHERE tier = ?", parameters: [.text("standard")])
            let total = try rows[0].integer(named: "total")
            return Int(total)
        }
        #expect(standardCount == 99)

        let indexCount = try await database.read { reader in
            let rows = try reader.query("SELECT COUNT(*) AS total FROM sqlite_master WHERE type = 'index' AND name = ?", parameters: [.text("idx_orders_tier")])
            let total = try rows[0].integer(named: "total")
            return Int(total)
        }
        #expect(indexCount == 1)

        await database.close()
        Self.removeFiles(path)
    }

    @Test("a failing migration step rolls back the whole transaction leaving the prior schema intact")
    func failingMigrationStepRollsBackAndPreservesSchema() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await Self.seedOrders(database, rowCount: 150)

        await #expect(throws: SQLiteError.self) {
            try await database.transaction { writer in
                try writer.execute("ALTER TABLE orders ADD COLUMN region TEXT NOT NULL DEFAULT 'east'")
                try writer.execute("ALTER TABLE orders ADD COLUMN region TEXT NOT NULL DEFAULT 'west'")
            }
        }

        let columns = try await Self.columnNames(database, table: "orders")
        #expect(columns == ["id", "reference", "amount"])
        #expect(columns.contains("region") == false)

        let rowCount = try await Self.countRows(database, table: "orders")
        #expect(rowCount == 150)

        let reference = try await database.read { reader in
            let rows = try reader.query("SELECT reference FROM orders WHERE id = ?", parameters: [.integer(75)])
            #expect(rows.count == 1)
            return try rows[0].text(named: "reference")
        }
        #expect(reference == "REF-75")

        await database.close()
        Self.removeFiles(path)
    }

    @Test("renaming a table keeps the data reachable under the new name")
    func renameTableKeepsDataReachable() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await Self.seedOrders(database, rowCount: 180)

        try await database.write { writer in
            try writer.execute("ALTER TABLE orders RENAME TO purchase_order")
        }

        let renamedCount = try await Self.countRows(database, table: "purchase_order")
        #expect(renamedCount == 180)

        let reference = try await database.read { reader in
            let rows = try reader.query("SELECT reference FROM purchase_order WHERE id = ?", parameters: [.integer(90)])
            #expect(rows.count == 1)
            return try rows[0].text(named: "reference")
        }
        #expect(reference == "REF-90")

        await #expect(throws: SQLiteError.self) {
            _ = try await database.read { reader in
                try reader.query("SELECT COUNT(*) AS total FROM orders")
            }
        }

        try await database.write { writer in
            _ = try writer.mutate(
                "INSERT INTO purchase_order(id, reference, amount) VALUES (?, ?, ?)",
                parameters: [.integer(181), .text("REF-181"), .real(362.0)]
            )
        }

        let afterInsert = try await Self.countRows(database, table: "purchase_order")
        #expect(afterInsert == 181)

        await database.close()
        Self.removeFiles(path)
    }
}
