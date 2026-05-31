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

@Suite("DXSQLite connectivity and lifecycle")
struct SQLiteConnectivityTests {

    static func makePath() -> String {
        NSTemporaryDirectory() + "dxsqlite-conn-\(UUID().uuidString).sqlite"
    }

    static func cleanUp(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    struct ScopedFailure: Error, Equatable {

        let marker: Int
    }

    @Test("opening a file location that does not yet exist creates the database file")
    func opensCreatesMissingFile() async throws {
        let path = Self.makePath()
        #expect(FileManager.default.fileExists(atPath: path) == false)

        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await database.write { writer in
            try writer.execute("CREATE TABLE catalog (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
            _ = try writer.mutate("INSERT INTO catalog (id, name) VALUES (1, 'widget')", parameters: [])
        }

        #expect(FileManager.default.fileExists(atPath: path))

        let rows = try await database.read { reader in
            try reader.query("SELECT name FROM catalog WHERE id = 1")
        }
        #expect(rows.count == 1)
        #expect(try rows[0].text(named: "name") == "widget")

        await database.close()
        Self.cleanUp(path)
    }

    @Test("two databases at the same file path both see committed data")
    func twoHandlesSameFileShareCommittedData() async throws {
        let path = Self.makePath()
        let writerDatabase = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await writerDatabase.write { writer in
            try writer.execute("CREATE TABLE orders (id INTEGER PRIMARY KEY, total REAL NOT NULL)")
            _ = try writer.mutate("INSERT INTO orders (id, total) VALUES (1, 42.5)", parameters: [])
        }

        let readerDatabase = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        let rows = try await readerDatabase.read { reader in
            try reader.query("SELECT total FROM orders WHERE id = 1")
        }
        #expect(rows.count == 1)
        #expect(try rows[0].double(named: "total") == 42.5)

        try await readerDatabase.write { writer in
            _ = try writer.mutate("INSERT INTO orders (id, total) VALUES (2, 7.0)", parameters: [])
        }

        let countRows = try await writerDatabase.read { reader in
            try reader.query("SELECT COUNT(*) AS n FROM orders")
        }
        #expect(try countRows[0].integer(named: "n") == 2)

        await writerDatabase.close()
        await readerDatabase.close()
        Self.cleanUp(path)
    }

    @Test("in-memory databases with the same name share data")
    func inMemorySameNameSharesData() async throws {
        let name = "dxsqlite-conn-mem-shared-\(UUID().uuidString)"
        let first = try await SQLite.connect(SQLiteConfiguration(location: .inMemory(name: name)))
        let second = try await SQLite.connect(SQLiteConfiguration(location: .inMemory(name: name)))

        try await first.write { writer in
            try writer.execute("CREATE TABLE ledger (id INTEGER PRIMARY KEY, amount INTEGER NOT NULL)")
            _ = try writer.mutate("INSERT INTO ledger (id, amount) VALUES (1, 1000)", parameters: [])
        }

        let rows = try await second.read { reader in
            try reader.query("SELECT amount FROM ledger WHERE id = 1")
        }
        #expect(rows.count == 1)
        #expect(try rows[0].integer(named: "amount") == 1000)

        await first.close()
        await second.close()
    }

    @Test("two different in-memory names are isolated")
    func inMemoryDifferentNamesAreIsolated() async throws {
        let nameOne = "dxsqlite-conn-mem-one-\(UUID().uuidString)"
        let nameTwo = "dxsqlite-conn-mem-two-\(UUID().uuidString)"
        let one = try await SQLite.connect(SQLiteConfiguration(location: .inMemory(name: nameOne)))
        let two = try await SQLite.connect(SQLiteConfiguration(location: .inMemory(name: nameTwo)))

        try await one.write { writer in
            try writer.execute("CREATE TABLE inventory (sku TEXT PRIMARY KEY, units INTEGER NOT NULL)")
            _ = try writer.mutate("INSERT INTO inventory (sku, units) VALUES ('A-1', 5)", parameters: [])
        }

        await #expect(throws: SQLiteError.self) {
            try await two.read { reader in
                try reader.query("SELECT units FROM inventory")
            }
        }

        await one.close()
        await two.close()
    }

    @Test("a committed write is visible to a freshly opened reader handle")
    func committedWriteVisibleToFreshReader() async throws {
        let path = Self.makePath()
        let writerDatabase = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await writerDatabase.write { writer in
            try writer.execute("CREATE TABLE shipments (id INTEGER PRIMARY KEY, code TEXT NOT NULL)")
            _ = try writer.mutate("INSERT INTO shipments (id, code) VALUES (1, 'SHP-100')", parameters: [])
        }
        await writerDatabase.close()

        let freshReader = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        let rows = try await freshReader.read { reader in
            try reader.query("SELECT code FROM shipments WHERE id = 1")
        }
        #expect(rows.count == 1)
        #expect(try rows[0].text(named: "code") == "SHP-100")

        await freshReader.close()
        Self.cleanUp(path)
    }

    @Test("reading after close throws databaseClosed")
    func readAfterCloseThrowsDatabaseClosed() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await database.write { writer in
            try writer.execute("CREATE TABLE accounts (id INTEGER PRIMARY KEY, balance INTEGER NOT NULL)")
            _ = try writer.mutate("INSERT INTO accounts (id, balance) VALUES (1, 250)", parameters: [])
        }
        await database.close()

        var thrown = SQLiteError.noCurrentDatabase
        do {
            _ = try await database.read { reader in
                try reader.query("SELECT balance FROM accounts")
            }
            Issue.record("expected read after close to throw")
        } catch {
            if let sqliteError = error as? SQLiteError {
                thrown = sqliteError
            } else {
                Issue.record("expected SQLiteError, received \(error)")
            }
        }
        #expect(thrown == SQLiteError.databaseClosed)

        Self.cleanUp(path)
    }

    @Test("withDatabase runs the body, returns its result, and closes afterward")
    func withDatabaseReturnsBodyResult() async throws {
        let path = Self.makePath()
        let total = try await SQLite.withDatabase(SQLiteConfiguration(location: .file(path: path))) { database in
            try await database.write { writer in
                try writer.execute("CREATE TABLE basket (id INTEGER PRIMARY KEY, quantity INTEGER NOT NULL)")
                _ = try writer.mutate("INSERT INTO basket (id, quantity) VALUES (1, 3)", parameters: [])
                _ = try writer.mutate("INSERT INTO basket (id, quantity) VALUES (2, 4)", parameters: [])
            }
            return try await database.read { reader in
                let rows = try reader.query("SELECT SUM(quantity) AS s FROM basket")
                return try rows[0].integer(named: "s")
            }
        }
        #expect(total == 7)

        Self.cleanUp(path)
    }

    @Test("withDatabase propagates a thrown error and still closes")
    func withDatabasePropagatesThrownError() async throws {
        let path = Self.makePath()
        var captured = ScopedFailure(marker: 0)
        do {
            _ = try await SQLite.withDatabase(SQLiteConfiguration(location: .file(path: path))) { database in
                try await database.write { writer in
                    try writer.execute("CREATE TABLE staging (id INTEGER PRIMARY KEY)")
                }
                throw ScopedFailure(marker: 99)
            }
            Issue.record("expected withDatabase to propagate the body error")
        } catch {
            if let failure = error as? ScopedFailure {
                captured = failure
            } else {
                Issue.record("expected ScopedFailure, received \(error)")
            }
        }
        #expect(captured == ScopedFailure(marker: 99))

        Self.cleanUp(path)
    }

    @Test("withCurrent binds the database so current returns it inside scope")
    func withCurrentReturnsBoundDatabase() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let resolved = try await SQLite.withCurrent(database) {
            try SQLite.current()
        }
        #expect(resolved === database)

        await database.close()
        Self.cleanUp(path)
    }

    @Test("withCurrent binding is visible to a nested async call")
    func withCurrentVisibleAcrossNestedAsyncCall() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        func resolveAmbient() async throws -> SQLiteDatabase {
            try SQLite.current()
        }

        let resolved = try await SQLite.withCurrent(database) {
            try await resolveAmbient()
        }
        #expect(resolved === database)

        await database.close()
        Self.cleanUp(path)
    }

    @Test("current outside any binding throws noCurrentDatabase")
    func currentOutsideBindingThrows() async throws {
        var thrown = SQLiteError.databaseClosed
        do {
            _ = try SQLite.current()
            Issue.record("expected current outside a binding to throw")
        } catch {
            thrown = error
        }
        #expect(thrown == SQLiteError.noCurrentDatabase)
    }

    @Test("connecting with a parent directory that does not exist throws cannotOpenDatabase")
    func connectInvalidParentThrowsCannotOpen() async throws {
        let missingParent = NSTemporaryDirectory() + "dxsqlite-conn-missing-\(UUID().uuidString)"
        let path = missingParent + "/nested/store.sqlite"

        await #expect(throws: SQLiteError.self) {
            _ = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        }

        var thrown = SQLiteError.databaseClosed
        do {
            _ = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
            Issue.record("expected connect to an unreachable path to throw")
        } catch {
            thrown = error
        }
        if case .cannotOpenDatabase = thrown {
            #expect(Bool(true))
        } else {
            Issue.record("expected cannotOpenDatabase, received \(thrown)")
        }
    }
}
