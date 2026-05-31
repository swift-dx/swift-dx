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

@Suite("DXSQLite error surface")
struct SQLiteErrorSurfaceTests {

    struct ExplodingEncodable: Encodable {

        func encode(to encoder: Encoder) throws {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(codingPath: [], debugDescription: "this value refuses to encode")
            )
        }
    }

    struct MismatchedRecord: Decodable {

        let quantity: Int64
    }

    static func temporaryPath() -> String {
        NSTemporaryDirectory() + "dxsqlite-errsurf-\(UUID().uuidString).sqlite"
    }

    static func removeDatabase(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    @Test("cannotOpenDatabase is thrown for a path in a missing directory")
    func cannotOpenDatabaseForMissingDirectory() async {
        let path = NSTemporaryDirectory() + "dxsqlite-errsurf-\(UUID().uuidString)/missing/store.sqlite"
        await #expect(throws: SQLiteError.self) {
            _ = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        }
    }

    @Test("cannotOpenDatabase carries a non-empty description")
    func cannotOpenDatabaseDescription() {
        let error = SQLiteError.cannotOpenDatabase(path: "/no/such/place.sqlite", code: 14, message: "unable to open database file")
        #expect(!"\(error)".isEmpty)
    }

    @Test("executeFailed is thrown for malformed SQL")
    func executeFailedForMalformedStatement() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        await #expect(throws: SQLiteError.self) {
            try await database.write { writer in
                try writer.execute("CREATE GARBAGE NONSENSE STATEMENT")
            }
        }

        await database.close()
        Self.removeDatabase(at: path)
    }

    @Test("executeFailed carries a non-empty description")
    func executeFailedDescription() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let captured = try await database.write { writer -> String in
            do {
                try writer.execute("CREATE GARBAGE NONSENSE STATEMENT")
                return ""
            } catch {
                guard let sqliteError = error as? SQLiteError else { return "" }
                switch sqliteError {
                case .executeFailed: return "\(sqliteError)"
                default: return ""
                }
            }
        }
        #expect(!captured.isEmpty)

        await database.close()
        Self.removeDatabase(at: path)
    }

    @Test("prepareFailed is thrown for an unresolved identifier")
    func prepareFailedForUnresolvedIdentifier() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let captured = try await database.read { reader -> String in
            do {
                _ = try reader.query("SELECT id FROM table_that_does_not_exist")
                return ""
            } catch {
                guard let sqliteError = error as? SQLiteError else { return "" }
                switch sqliteError {
                case .prepareFailed: return "\(sqliteError)"
                default: return ""
                }
            }
        }
        #expect(!captured.isEmpty)

        await database.close()
        Self.removeDatabase(at: path)
    }

    @Test("bindFailed is thrown when more parameters are supplied than placeholders")
    func bindFailedForExcessParameters() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            try writer.execute("CREATE TABLE catalog (id INTEGER PRIMARY KEY, name TEXT)")
        }

        let captured = try await database.write { writer -> String in
            do {
                _ = try writer.mutate("INSERT INTO catalog (name) VALUES (?)", parameters: [.text("Widget"), .text("Surplus")])
                return ""
            } catch {
                guard let sqliteError = error as? SQLiteError else { return "" }
                switch sqliteError {
                case .bindFailed: return "\(sqliteError)"
                default: return ""
                }
            }
        }
        #expect(!captured.isEmpty)

        await database.close()
        Self.removeDatabase(at: path)
    }

    @Test("columnNotFound is thrown for an absent column name")
    func columnNotFoundForAbsentName() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let row = try await database.read { reader in
            try reader.query("SELECT 7 AS quantity")
        }
        #expect(row.count == 1)

        do {
            _ = try row[0].value(named: "missing_column")
            #expect(Bool(false))
        } catch {
            switch error {
            case .columnNotFound:
                #expect(!"\(error)".isEmpty)
            default:
                #expect(Bool(false))
            }
        }

        await database.close()
        Self.removeDatabase(at: path)
    }

    @Test("valueTypeMismatch is thrown by a typed accessor on the wrong type")
    func valueTypeMismatchForWrongAccessor() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let row = try await database.read { reader in
            try reader.query("SELECT 'a string value' AS label")
        }
        #expect(row.count == 1)

        do {
            _ = try row[0].integer(named: "label")
            #expect(Bool(false))
        } catch {
            switch error {
            case .valueTypeMismatch(let expected, let actual):
                #expect(expected == .integer)
                #expect(actual == .text)
                #expect(!"\(error)".isEmpty)
            default:
                #expect(Bool(false))
            }
        }

        await database.close()
        Self.removeDatabase(at: path)
    }

    @Test("decodingFailed is thrown when a row cannot decode into the target type")
    func decodingFailedForIncompatibleStruct() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let captured = try await database.read { reader -> String in
            do {
                _ = try reader.query("SELECT 'not an integer' AS quantity", as: MismatchedRecord.self)
                return ""
            } catch {
                guard let sqliteError = error as? SQLiteError else { return "" }
                switch sqliteError {
                case .valueTypeMismatch, .decodingFailed: return "\(sqliteError)"
                default: return ""
                }
            }
        }
        #expect(!captured.isEmpty)

        await database.close()
        Self.removeDatabase(at: path)
    }

    @Test("encodingFailed is thrown when an Encodable refuses to encode to JSON")
    func encodingFailedForExplodingEncodable() {
        do {
            _ = try SQLiteValue.json(ExplodingEncodable())
            #expect(Bool(false))
        } catch {
            switch error {
            case .encodingFailed:
                #expect(!"\(error)".isEmpty)
            default:
                #expect(Bool(false))
            }
        }
    }

    @Test("blobFailed is thrown when opening a blob on a missing table")
    func blobFailedForMissingTable() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        await #expect(throws: SQLiteError.self) {
            try await database.write { writer in
                try writer.withBlob(table: "no_such_table", column: "payload", rowID: 1) { _ in }
            }
        }

        await database.close()
        Self.removeDatabase(at: path)
    }

    @Test("blobFailed carries a non-empty description")
    func blobFailedDescription() {
        let error = SQLiteError.blobFailed(operation: "open ledger.payload", code: 1, message: "no such table: ledger")
        #expect(!"\(error)".isEmpty)
    }

    @Test("sessionFailed is thrown when applying a garbage changeset")
    func sessionFailedForGarbageChangeset() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let captured = try await database.write { writer -> String in
            do {
                try writer.applyChangeset([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04])
                return ""
            } catch {
                guard let sqliteError = error as? SQLiteError else { return "" }
                switch sqliteError {
                case .sessionFailed: return "\(sqliteError)"
                default: return ""
                }
            }
        }
        #expect(!captured.isEmpty)

        await database.close()
        Self.removeDatabase(at: path)
    }

    @Test("a virtual table with malformed schema SQL fails when first queried")
    func malformedVirtualTableSchemaFailsOnQuery() async throws {
        let path = Self.temporaryPath()
        let provider = SQLiteStaticTable(
            name: "ledger",
            columns: ["this is not a valid column declaration ((("],
            rows: [[.integer(1)]]
        )
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), virtualTables: [provider]))

        await #expect(throws: SQLiteError.self) {
            _ = try await database.read { reader in
                try reader.query("SELECT * FROM ledger")
            }
        }

        await database.close()
        Self.removeDatabase(at: path)
    }

    @Test("virtualTableRegistrationFailed carries a non-empty description")
    func virtualTableRegistrationFailedDescription() {
        let error = SQLiteError.virtualTableRegistrationFailed(name: "ledger", code: 1, message: "near \"(\": syntax error")
        #expect(!"\(error)".isEmpty)
    }

    @Test("databaseClosed is thrown when reading after the database is closed")
    func databaseClosedAfterClose() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        await database.close()

        await #expect(throws: SQLiteError.databaseClosed) {
            _ = try await database.read { reader in
                try reader.query("SELECT 1 AS one")
            }
        }

        #expect(!"\(SQLiteError.databaseClosed)".isEmpty)
        Self.removeDatabase(at: path)
    }

    @Test("noCurrentDatabase is thrown when current is read outside any binding")
    func noCurrentDatabaseOutsideBinding() {
        #expect(throws: SQLiteError.noCurrentDatabase) {
            _ = try SQLite.current()
        }
        #expect(!"\(SQLiteError.noCurrentDatabase)".isEmpty)
    }

    @Test("current returns the bound database inside withCurrent and throws after it ends")
    func noCurrentDatabaseAfterBindingEnds() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await SQLite.withCurrent(database) {
            let bound = try SQLite.current()
            let rows = try await bound.read { reader in
                try reader.query("SELECT 1 AS one")
            }
            #expect(try rows[0].integer(named: "one") == 1)
        }

        #expect(throws: SQLiteError.noCurrentDatabase) {
            _ = try SQLite.current()
        }

        await database.close()
        Self.removeDatabase(at: path)
    }
}
