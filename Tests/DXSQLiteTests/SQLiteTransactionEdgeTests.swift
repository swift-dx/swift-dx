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

@Suite("DXSQLite transaction edge cases")
struct SQLiteTransactionEdgeTests {

    static func makePath() -> String {
        NSTemporaryDirectory() + "dxsqlite-txedge-\(UUID().uuidString).sqlite"
    }

    static func removeDatabaseFiles(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    static func createOrderTable(_ database: SQLiteDatabase) async throws {
        try await database.write { writer in
            try writer.execute("CREATE TABLE orders (id INTEGER PRIMARY KEY, sku TEXT NOT NULL UNIQUE, quantity INTEGER NOT NULL)")
        }
    }

    @Test("an empty transaction with no mutations succeeds and returns its value")
    func emptyTransactionReturnsValue() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let returned = try await database.transaction { _ in
            42
        }
        #expect(returned == 42)

        await database.close()
        Self.removeDatabaseFiles(at: path)
    }

    @Test("a read-only transaction containing only queries succeeds")
    func readOnlyTransactionSucceeds() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await Self.createOrderTable(database)
        try await database.write { writer in
            _ = try writer.mutate("INSERT INTO orders (sku, quantity) VALUES ('SKU-1', 5)", parameters: [])
        }

        let count = try await database.transaction { writer in
            let rows = try writer.query("SELECT COUNT(*) AS n FROM orders")
            return try rows[0].integer(named: "n")
        }
        #expect(count == 1)

        await database.close()
        Self.removeDatabaseFiles(at: path)
    }

    @Test("a transaction with over one thousand inserts commits and all rows persist")
    func longTransactionCommitsAllRows() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await Self.createOrderTable(database)

        let insertCount = 1500
        try await database.transaction { writer in
            for index in 0..<insertCount {
                _ = try writer.mutate("INSERT INTO orders (id, sku, quantity) VALUES (?, ?, ?)", parameters: [.integer(Int64(index)), .text("SKU-\(index)"), .integer(Int64(index % 7))])
            }
        }

        let total = try await database.read { reader in
            let rows = try reader.query("SELECT COUNT(*) AS n FROM orders")
            return try rows[0].integer(named: "n")
        }
        #expect(total == Int64(insertCount))

        await database.close()
        Self.removeDatabaseFiles(at: path)
    }

    @Test("a constraint violation mid-transaction rolls back every prior write")
    func constraintViolationRollsBackWholeTransaction() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await Self.createOrderTable(database)

        await #expect(throws: SQLiteError.self) {
            try await database.transaction { writer in
                _ = try writer.mutate("INSERT INTO orders (sku, quantity) VALUES ('SKU-A', 1)", parameters: [])
                _ = try writer.mutate("INSERT INTO orders (sku, quantity) VALUES ('SKU-B', 2)", parameters: [])
                _ = try writer.mutate("INSERT INTO orders (sku, quantity) VALUES ('SKU-A', 3)", parameters: [])
            }
        }

        let remaining = try await database.read { reader in
            let rows = try reader.query("SELECT COUNT(*) AS n FROM orders")
            return try rows[0].integer(named: "n")
        }
        #expect(remaining == 0)

        await database.close()
        Self.removeDatabaseFiles(at: path)
    }

    @Test("a writer transaction nested inside a write commits when both succeed")
    func nestedWriterTransactionCommits() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await Self.createOrderTable(database)

        try await database.write { writer in
            _ = try writer.mutate("INSERT INTO orders (sku, quantity) VALUES ('SKU-OUTER', 10)", parameters: [])
            try writer.transaction { inner in
                _ = try inner.mutate("INSERT INTO orders (sku, quantity) VALUES ('SKU-INNER-1', 11)", parameters: [])
                _ = try inner.mutate("INSERT INTO orders (sku, quantity) VALUES ('SKU-INNER-2', 12)", parameters: [])
            }
        }

        let rows = try await database.read { reader in
            try reader.query("SELECT sku, quantity FROM orders ORDER BY quantity")
        }
        #expect(rows.count == 3)
        #expect(try rows[0].text(named: "sku") == "SKU-OUTER")
        #expect(try rows[1].text(named: "sku") == "SKU-INNER-1")
        #expect(try rows[2].integer(named: "quantity") == 12)

        await database.close()
        Self.removeDatabaseFiles(at: path)
    }

    @Test("a transaction body that throws rolls back fully and propagates the error")
    func throwingBodyRollsBackAndPropagates() async throws {
        struct DeliberateFailure: Error, Sendable {}

        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await Self.createOrderTable(database)

        var observedDeliberateFailure = false
        do {
            try await database.transaction { writer in
                _ = try writer.mutate("INSERT INTO orders (sku, quantity) VALUES ('SKU-DOOMED', 99)", parameters: [])
                throw DeliberateFailure()
            }
        } catch is DeliberateFailure {
            observedDeliberateFailure = true
        }
        #expect(observedDeliberateFailure)

        let remaining = try await database.read { reader in
            let rows = try reader.query("SELECT COUNT(*) AS n FROM orders")
            return try rows[0].integer(named: "n")
        }
        #expect(remaining == 0)

        await database.close()
        Self.removeDatabaseFiles(at: path)
    }

    @Test("under WAL a fresh reader sees committed data but never uncommitted writes")
    func walReaderSeesCommittedNeverUncommitted() async throws {
        struct DeliberateFailure: Error, Sendable {}

        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await Self.createOrderTable(database)

        try await database.transaction { writer in
            _ = try writer.mutate("INSERT INTO orders (sku, quantity) VALUES ('SKU-COMMITTED', 1)", parameters: [])
        }

        let afterCommit = try await database.read { reader in
            let rows = try reader.query("SELECT sku FROM orders")
            return try rows[0].text(named: "sku")
        }
        #expect(afterCommit == "SKU-COMMITTED")

        var observedDeliberateFailure = false
        do {
            try await database.transaction { writer in
                _ = try writer.mutate("INSERT INTO orders (sku, quantity) VALUES ('SKU-NEVER-VISIBLE', 2)", parameters: [])
                throw DeliberateFailure()
            }
        } catch is DeliberateFailure {
            observedDeliberateFailure = true
        }
        #expect(observedDeliberateFailure)

        let visibleSkus = try await database.read { reader in
            let rows = try reader.query("SELECT sku FROM orders ORDER BY sku")
            return try rows.map { try $0.text(named: "sku") }
        }
        #expect(visibleSkus == ["SKU-COMMITTED"])

        await database.close()
        Self.removeDatabaseFiles(at: path)
    }
}
