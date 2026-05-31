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

@Suite("DXSQLite blob, backup, and session edge cases")
struct SQLiteBlobBackupSessionEdgeTests {

    static let prefix = "dxsqlite-blobsess"

    static func temporaryPath() -> String {
        NSTemporaryDirectory() + "\(prefix)-\(UUID().uuidString).sqlite"
    }

    static func removeDatabaseFiles(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    @Test("a pre-sized blob is written and partially read back at several offsets")
    func presizedBlobWriteAndPartialReads() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let rowID = try await database.write { writer in
            try writer.execute("CREATE TABLE document (id INTEGER PRIMARY KEY, payload BLOB)")
            _ = try writer.mutate("INSERT INTO document (id, payload) VALUES (1, zeroblob(16))", parameters: [])
            return writer.lastInsertRowID
        }

        try await database.write { writer in
            try writer.withBlob(table: "document", column: "payload", rowID: rowID) { blob in
                try blob.write([1, 2, 3, 4], at: 0)
                try blob.write([9, 8, 7, 6], at: 8)
            }
        }

        let readBack = try await database.read { reader in
            try reader.withBlob(table: "document", column: "payload", rowID: rowID) { blob in
                let head = try blob.read(count: 4, at: 0)
                let middle = try blob.read(count: 4, at: 8)
                let single = try blob.read(count: 1, at: 2)
                return [head, middle, single]
            }
        }
        #expect(readBack[0] == [1, 2, 3, 4])
        #expect(readBack[1] == [9, 8, 7, 6])
        #expect(readBack[2] == [3])

        await database.close()
        Self.removeDatabaseFiles(at: path)
    }

    @Test("a blob reports its declared size and reads exactly the requested in-bounds range")
    func blobCountAndInBoundsRange() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let rowID = try await database.write { writer in
            try writer.execute("CREATE TABLE document (id INTEGER PRIMARY KEY, payload BLOB)")
            _ = try writer.mutate("INSERT INTO document (id, payload) VALUES (1, zeroblob(32))", parameters: [])
            return writer.lastInsertRowID
        }

        try await database.write { writer in
            try writer.withBlob(table: "document", column: "payload", rowID: rowID) { blob in
                try blob.write([10, 20, 30, 40, 50, 60], at: 4)
            }
        }

        let observed = try await database.read { reader in
            try reader.withBlob(table: "document", column: "payload", rowID: rowID) { blob in
                let declaredSize = blob.count
                let slice = try blob.read(count: 6, at: 4)
                return (declaredSize, slice)
            }
        }
        #expect(observed.0 == 32)
        #expect(observed.1 == [10, 20, 30, 40, 50, 60])

        await database.close()
        Self.removeDatabaseFiles(at: path)
    }

    @Test("opening a blob on a nonexistent table throws")
    func openBlobOnMissingTableThrows() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            try writer.execute("CREATE TABLE document (id INTEGER PRIMARY KEY, payload BLOB)")
            _ = try writer.mutate("INSERT INTO document (id, payload) VALUES (1, zeroblob(8))", parameters: [])
        }

        await #expect(throws: SQLiteError.self) {
            try await database.read { reader in
                try reader.withBlob(table: "ledger", column: "payload", rowID: 1) { blob in
                    _ = blob.count
                }
            }
        }

        await database.close()
        Self.removeDatabaseFiles(at: path)
    }

    @Test("opening a blob on a nonexistent column throws")
    func openBlobOnMissingColumnThrows() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            try writer.execute("CREATE TABLE document (id INTEGER PRIMARY KEY, payload BLOB)")
            _ = try writer.mutate("INSERT INTO document (id, payload) VALUES (1, zeroblob(8))", parameters: [])
        }

        await #expect(throws: SQLiteError.self) {
            try await database.read { reader in
                try reader.withBlob(table: "document", column: "attachment", rowID: 1) { blob in
                    _ = blob.count
                }
            }
        }

        await database.close()
        Self.removeDatabaseFiles(at: path)
    }

    @Test("backup to a fresh path produces a file that opens with the same rows")
    func backupToFreshPathReproducesRows() async throws {
        let sourcePath = Self.temporaryPath()
        let backupPath = Self.temporaryPath()
        let source = try await SQLite.connect(SQLiteConfiguration(location: .file(path: sourcePath)))

        try await source.write { writer in
            try writer.execute("CREATE TABLE product (id INTEGER PRIMARY KEY, name TEXT NOT NULL, price REAL NOT NULL)")
            _ = try writer.mutate("INSERT INTO product (id, name, price) VALUES (1, 'Notebook', 4.50)", parameters: [])
            _ = try writer.mutate("INSERT INTO product (id, name, price) VALUES (2, 'Pencil', 0.75)", parameters: [])
        }

        try await source.write { writer in
            try writer.backup(toFile: backupPath)
        }
        #expect(FileManager.default.fileExists(atPath: backupPath))

        let restored = try await SQLite.connect(SQLiteConfiguration(location: .file(path: backupPath)))
        let rows = try await restored.read { reader in
            try reader.query("SELECT name, price FROM product ORDER BY id")
        }
        #expect(rows.count == 2)
        #expect(try rows[0].text(named: "name") == "Notebook")
        #expect(try rows[0].double(named: "price") == 4.50)
        #expect(try rows[1].text(named: "name") == "Pencil")
        #expect(try rows[1].double(named: "price") == 0.75)

        await source.close()
        await restored.close()
        Self.removeDatabaseFiles(at: sourcePath)
        Self.removeDatabaseFiles(at: backupPath)
    }

    @Test("backup over an existing file replaces its contents")
    func backupOverExistingFileReplacesContents() async throws {
        let sourcePath = Self.temporaryPath()
        let destinationPath = Self.temporaryPath()
        let source = try await SQLite.connect(SQLiteConfiguration(location: .file(path: sourcePath)))
        let preexisting = try await SQLite.connect(SQLiteConfiguration(location: .file(path: destinationPath)))

        try await source.write { writer in
            try writer.execute("CREATE TABLE entry (id INTEGER PRIMARY KEY, label TEXT NOT NULL)")
            _ = try writer.mutate("INSERT INTO entry (id, label) VALUES (1, 'fresh')", parameters: [])
        }

        try await preexisting.write { writer in
            try writer.execute("CREATE TABLE stale (id INTEGER PRIMARY KEY, marker TEXT NOT NULL)")
            _ = try writer.mutate("INSERT INTO stale (id, marker) VALUES (1, 'old')", parameters: [])
        }
        await preexisting.close()

        try await source.write { writer in
            try writer.backup(toFile: destinationPath)
        }

        let restored = try await SQLite.connect(SQLiteConfiguration(location: .file(path: destinationPath)))
        let entries = try await restored.read { reader in
            try reader.query("SELECT label FROM entry ORDER BY id")
        }
        #expect(entries.count == 1)
        #expect(try entries[0].text(named: "label") == "fresh")

        await #expect(throws: SQLiteError.self) {
            try await restored.read { reader in
                try reader.query("SELECT marker FROM stale")
            }
        }

        await source.close()
        await restored.close()
        Self.removeDatabaseFiles(at: sourcePath)
        Self.removeDatabaseFiles(at: destinationPath)
    }

    @Test("serialize returns non-empty bytes that are stable across repeated calls")
    func serializeReturnsStableNonEmptyBytes() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            try writer.execute("CREATE TABLE account (id INTEGER PRIMARY KEY, owner TEXT NOT NULL, balance INTEGER NOT NULL)")
            _ = try writer.mutate("INSERT INTO account (id, owner, balance) VALUES (1, 'east-region', 1200)", parameters: [])
            _ = try writer.mutate("INSERT INTO account (id, owner, balance) VALUES (2, 'west-region', 3400)", parameters: [])
        }

        let firstSnapshot = try await database.read { reader in
            try reader.serialize()
        }
        let secondSnapshot = try await database.read { reader in
            try reader.serialize()
        }
        #expect(firstSnapshot.count > 0)
        #expect(firstSnapshot == secondSnapshot)

        await database.close()
        Self.removeDatabaseFiles(at: path)
    }

    @Test("a changeset over insert then update of one row reproduces the final state")
    func changesetInsertThenUpdateReproducesFinalState() async throws {
        let sourcePath = Self.temporaryPath()
        let targetPath = Self.temporaryPath()
        let source = try await SQLite.connect(SQLiteConfiguration(location: .file(path: sourcePath)))
        let target = try await SQLite.connect(SQLiteConfiguration(location: .file(path: targetPath)))

        for database in [source, target] {
            try await database.write { writer in
                try writer.execute("CREATE TABLE inventory (id INTEGER PRIMARY KEY, quantity INTEGER NOT NULL)")
            }
        }

        let changeset = try await source.write { writer in
            try writer.recordingChangeset { recording in
                _ = try recording.mutate("INSERT INTO inventory (id, quantity) VALUES (1, 5)", parameters: [])
                _ = try recording.mutate("UPDATE inventory SET quantity = 42 WHERE id = 1", parameters: [])
            }
        }
        #expect(changeset.count > 0)

        try await target.write { writer in
            try writer.applyChangeset(changeset)
        }

        let rows = try await target.read { reader in
            try reader.query("SELECT quantity FROM inventory ORDER BY id")
        }
        #expect(rows.count == 1)
        #expect(try rows[0].integer(named: "quantity") == 42)

        await source.close()
        await target.close()
        Self.removeDatabaseFiles(at: sourcePath)
        Self.removeDatabaseFiles(at: targetPath)
    }

    @Test("applying a changeset whose insert conflicts with an existing row omits the change and does not throw")
    func conflictingInsertIsOmittedWithoutThrowing() async throws {
        let sourcePath = Self.temporaryPath()
        let targetPath = Self.temporaryPath()
        let source = try await SQLite.connect(SQLiteConfiguration(location: .file(path: sourcePath)))
        let target = try await SQLite.connect(SQLiteConfiguration(location: .file(path: targetPath)))

        for database in [source, target] {
            try await database.write { writer in
                try writer.execute("CREATE TABLE customer (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
            }
        }

        try await target.write { writer in
            _ = try writer.mutate("INSERT INTO customer (id, name) VALUES (1, 'preexisting')", parameters: [])
        }

        let changeset = try await source.write { writer in
            try writer.recordingChangeset { recording in
                _ = try recording.mutate("INSERT INTO customer (id, name) VALUES (1, 'incoming')", parameters: [])
            }
        }
        #expect(changeset.count > 0)

        try await target.write { writer in
            try writer.applyChangeset(changeset)
        }

        let rows = try await target.read { reader in
            try reader.query("SELECT name FROM customer ORDER BY id")
        }
        #expect(rows.count == 1)
        #expect(try rows[0].text(named: "name") == "preexisting")

        await source.close()
        await target.close()
        Self.removeDatabaseFiles(at: sourcePath)
        Self.removeDatabaseFiles(at: targetPath)
    }
}
