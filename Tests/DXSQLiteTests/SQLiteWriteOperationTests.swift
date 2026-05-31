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

@Suite("DXSQLite write operations")
struct SQLiteWriteOperationTests {

    static let temporaryPrefix = "dxsqlite-write"

    static func makeTemporaryPath() -> String {
        NSTemporaryDirectory() + "\(temporaryPrefix)-\(UUID().uuidString).sqlite"
    }

    static func removeTemporaryFiles(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    @Test("execute runs DDL and an INSERT mutate reports one affected row")
    func executeDDLAndInsertReportsOneRow() async throws {
        let path = Self.makeTemporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let inserted = try await database.write { writer in
            try writer.execute("CREATE TABLE product (id INTEGER PRIMARY KEY, name TEXT NOT NULL, price REAL NOT NULL)")
            return try writer.mutate("INSERT INTO product (name, price) VALUES ('Widget', 9.99)", parameters: [])
        }
        #expect(inserted == 1)

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("UPDATE reports the count of matching rows")
    func updateReportsMatchingRowCount() async throws {
        let path = Self.makeTemporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let affected = try await database.write { writer in
            try writer.execute("CREATE TABLE product (id INTEGER PRIMARY KEY, category TEXT NOT NULL, price REAL NOT NULL)")
            _ = try writer.mutate("INSERT INTO product (category, price) VALUES ('books', 10.0)", parameters: [])
            _ = try writer.mutate("INSERT INTO product (category, price) VALUES ('books', 12.0)", parameters: [])
            _ = try writer.mutate("INSERT INTO product (category, price) VALUES ('toys', 5.0)", parameters: [])
            return try writer.mutate("UPDATE product SET price = price + 1.0 WHERE category = 'books'", parameters: [])
        }
        #expect(affected == 2)

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("DELETE reports the count of deleted rows")
    func deleteReportsDeletedRowCount() async throws {
        let path = Self.makeTemporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let deleted = try await database.write { writer in
            try writer.execute("CREATE TABLE product (id INTEGER PRIMARY KEY, status TEXT NOT NULL)")
            _ = try writer.mutate("INSERT INTO product (status) VALUES ('active')", parameters: [])
            _ = try writer.mutate("INSERT INTO product (status) VALUES ('retired')", parameters: [])
            _ = try writer.mutate("INSERT INTO product (status) VALUES ('retired')", parameters: [])
            return try writer.mutate("DELETE FROM product WHERE status = 'retired'", parameters: [])
        }
        #expect(deleted == 2)

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("a WHERE clause matching nothing reports zero affected rows")
    func updateMatchingNothingReportsZero() async throws {
        let path = Self.makeTemporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let affected = try await database.write { writer in
            try writer.execute("CREATE TABLE product (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
            _ = try writer.mutate("INSERT INTO product (name) VALUES ('Widget')", parameters: [])
            return try writer.mutate("UPDATE product SET name = 'Gadget' WHERE name = 'Absent'", parameters: [])
        }
        #expect(affected == 0)

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("lastInsertRowID reports the most recent INSERT and survives a following DELETE")
    func lastInsertRowIDUnchangedByDelete() async throws {
        let path = Self.makeTemporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let rowIDAfterDelete = try await database.write { writer in
            try writer.execute("CREATE TABLE product (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
            _ = try writer.mutate("INSERT INTO product (name) VALUES ('First')", parameters: [])
            _ = try writer.mutate("INSERT INTO product (name) VALUES ('Second')", parameters: [])
            let rowIDAfterInsert = writer.lastInsertRowID
            _ = try writer.mutate("DELETE FROM product WHERE name = 'First'", parameters: [])
            return (rowIDAfterInsert, writer.lastInsertRowID)
        }
        #expect(rowIDAfterDelete.0 == 2)
        #expect(rowIDAfterDelete.1 == 2)

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("multiple sequential INSERTs advance lastInsertRowID")
    func sequentialInsertsAdvanceLastInsertRowID() async throws {
        let path = Self.makeTemporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let rowIDs = try await database.write { writer -> [Int64] in
            try writer.execute("CREATE TABLE product (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
            var captured: [Int64] = []
            for ordinal in 1...4 {
                _ = try writer.mutate("INSERT INTO product (name) VALUES (?)", parameters: [.text("item-\(ordinal)")])
                captured.append(writer.lastInsertRowID)
            }
            return captured
        }
        #expect(rowIDs == [1, 2, 3, 4])

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("a large single UPDATE reports the correct changed-row count")
    func largeUpdateReportsCorrectCount() async throws {
        let path = Self.makeTemporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let affected = try await database.write { writer -> Int in
            try writer.execute("CREATE TABLE product (id INTEGER PRIMARY KEY, quantity INTEGER NOT NULL)")
            try writer.execute("BEGIN IMMEDIATE;")
            for ordinal in 1...5000 {
                _ = try writer.mutate("INSERT INTO product (quantity) VALUES (?)", parameters: [.integer(Int64(ordinal))])
            }
            try writer.execute("COMMIT;")
            return try writer.mutate("UPDATE product SET quantity = quantity + 1", parameters: [])
        }
        #expect(affected == 5000)

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("a large single DELETE reports the correct changed-row count")
    func largeDeleteReportsCorrectCount() async throws {
        let path = Self.makeTemporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let deleted = try await database.write { writer -> Int in
            try writer.execute("CREATE TABLE product (id INTEGER PRIMARY KEY, quantity INTEGER NOT NULL)")
            try writer.execute("BEGIN IMMEDIATE;")
            for ordinal in 1...5000 {
                _ = try writer.mutate("INSERT INTO product (quantity) VALUES (?)", parameters: [.integer(Int64(ordinal))])
            }
            try writer.execute("COMMIT;")
            return try writer.mutate("DELETE FROM product", parameters: [])
        }
        #expect(deleted == 5000)

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("mutate with a syntax error throws executeFailed")
    func mutateWithSyntaxErrorThrows() async throws {
        let path = Self.makeTemporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        await #expect(throws: SQLiteError.self) {
            try await database.write { writer in
                _ = try writer.mutate("INSERTZ INTO nothing VALUES (1)", parameters: [])
            }
        }

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("execute against a nonexistent table throws executeFailed")
    func executeAgainstNonexistentTableThrows() async throws {
        let path = Self.makeTemporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        await #expect(throws: SQLiteError.self) {
            try await database.write { writer in
                try writer.execute("INSERT INTO missing_table (id) VALUES (1)")
            }
        }

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("a UNIQUE constraint violation throws")
    func uniqueConstraintViolationThrows() async throws {
        let path = Self.makeTemporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            try writer.execute("CREATE TABLE product (id INTEGER PRIMARY KEY, sku TEXT NOT NULL UNIQUE)")
            _ = try writer.mutate("INSERT INTO product (sku) VALUES ('SKU-1')", parameters: [])
        }

        await #expect(throws: SQLiteError.self) {
            try await database.write { writer in
                _ = try writer.mutate("INSERT INTO product (sku) VALUES ('SKU-1')", parameters: [])
            }
        }

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("a PRIMARY KEY collision throws")
    func primaryKeyCollisionThrows() async throws {
        let path = Self.makeTemporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            try writer.execute("CREATE TABLE product (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
            _ = try writer.mutate("INSERT INTO product (id, name) VALUES (1, 'First')", parameters: [])
        }

        await #expect(throws: SQLiteError.self) {
            try await database.write { writer in
                _ = try writer.mutate("INSERT INTO product (id, name) VALUES (1, 'Duplicate')", parameters: [])
            }
        }

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("a FOREIGN KEY violation throws with enforcement on by default")
    func foreignKeyViolationThrows() async throws {
        let path = Self.makeTemporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            try writer.execute("CREATE TABLE category (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
            try writer.execute("CREATE TABLE product (id INTEGER PRIMARY KEY, category_id INTEGER NOT NULL REFERENCES category(id))")
        }

        await #expect(throws: SQLiteError.self) {
            try await database.write { writer in
                _ = try writer.mutate("INSERT INTO product (category_id) VALUES (999)", parameters: [])
            }
        }

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("a CHECK constraint violation throws")
    func checkConstraintViolationThrows() async throws {
        let path = Self.makeTemporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            try writer.execute("CREATE TABLE product (id INTEGER PRIMARY KEY, price REAL NOT NULL CHECK (price > 0))")
        }

        await #expect(throws: SQLiteError.self) {
            try await database.write { writer in
                _ = try writer.mutate("INSERT INTO product (price) VALUES (-5.0)", parameters: [])
            }
        }

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("mutate with the wrong number of bound parameters throws")
    func mutateWithWrongParameterCountThrows() async throws {
        let path = Self.makeTemporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            try writer.execute("CREATE TABLE product (id INTEGER PRIMARY KEY, name TEXT NOT NULL, price REAL NOT NULL)")
        }

        await #expect(throws: SQLiteError.self) {
            try await database.write { writer in
                _ = try writer.mutate("INSERT INTO product (name, price) VALUES (?, ?)", parameters: [.text("Widget")])
            }
        }

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("a parameterized INSERT round-trips every SQLiteValue kind on read-back")
    func parameterizedInsertRoundTripsEveryValueKind() async throws {
        let path = Self.makeTemporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let blobBytes: [UInt8] = [0x00, 0x01, 0x7F, 0x80, 0xFF]
        try await database.write { writer in
            try writer.execute("CREATE TABLE record (id INTEGER PRIMARY KEY, amount INTEGER, ratio REAL, label TEXT, payload BLOB, absent TEXT)")
            _ = try writer.mutate(
                "INSERT INTO record (amount, ratio, label, payload, absent) VALUES (?, ?, ?, ?, ?)",
                parameters: [.integer(42), .real(3.5), .text("invoice"), .blob(blobBytes), .null]
            )
        }

        let rows = try await database.read { reader in
            try reader.query("SELECT amount, ratio, label, payload, absent FROM record")
        }
        #expect(rows.count == 1)
        #expect(try rows[0].integer(named: "amount") == 42)
        #expect(try rows[0].double(named: "ratio") == 3.5)
        #expect(try rows[0].text(named: "label") == "invoice")
        #expect(try rows[0].blob(named: "payload") == blobBytes)
        #expect(try rows[0].value(named: "absent") == .null)

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }
}
