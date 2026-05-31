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

@Suite("DXSQLite read edge cases")
struct SQLiteReadEdgeTests {

    static let temporaryPrefix = "dxsqlite-readedge"

    static func makePath() -> String {
        NSTemporaryDirectory() + "\(temporaryPrefix)-\(UUID().uuidString).sqlite"
    }

    static func removeTemporaryFiles(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    @Test("a query matching no rows returns an empty array")
    func emptyQueryReturnsEmptyArray() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            try writer.execute("CREATE TABLE item (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
        }

        let rows: [SQLiteRow] = try await database.read { reader in
            try reader.query("SELECT id, name FROM item WHERE id = 999")
        }
        #expect(rows.isEmpty)

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("a ten thousand row query returns every row in ascending order")
    func tenThousandRowsReturnInOrder() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.transaction { writer in
            try writer.execute("CREATE TABLE counter (n INTEGER PRIMARY KEY)")
            for value in 0..<10_000 {
                _ = try writer.mutate("INSERT INTO counter (n) VALUES (?)", parameters: [.integer(Int64(value))])
            }
        }

        let rows: [SQLiteRow] = try await database.read { reader in
            try reader.query("SELECT n FROM counter ORDER BY n ASC")
        }
        #expect(rows.count == 10_000)
        #expect(try rows[0].integer(named: "n") == 0)
        #expect(try rows[9_999].integer(named: "n") == 9_999)
        var matches = true
        for index in 0..<rows.count where (try? rows[index].integer(named: "n")) != Int64(index) {
            matches = false
        }
        #expect(matches)

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("a multi-megabyte text value round-trips exactly")
    func multiMegabyteTextRoundTrips() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let large = String(repeating: "abcdefghij", count: 300_000)
        try await database.write { writer in
            try writer.execute("CREATE TABLE document (id INTEGER PRIMARY KEY, body TEXT NOT NULL)")
            _ = try writer.mutate("INSERT INTO document (body) VALUES (?)", parameters: [.text(large)])
        }

        let rows: [SQLiteRow] = try await database.read { reader in
            try reader.query("SELECT body FROM document")
        }
        #expect(rows.count == 1)
        #expect(try rows[0].text(named: "body") == large)

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("a multi-megabyte blob value round-trips exactly")
    func multiMegabyteBlobRoundTrips() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let large: [UInt8] = (0..<3_000_000).map { UInt8($0 % 256) }
        try await database.write { writer in
            try writer.execute("CREATE TABLE attachment (id INTEGER PRIMARY KEY, data BLOB NOT NULL)")
            _ = try writer.mutate("INSERT INTO attachment (data) VALUES (?)", parameters: [.blob(large)])
        }

        let rows: [SQLiteRow] = try await database.read { reader in
            try reader.query("SELECT data FROM attachment")
        }
        #expect(rows.count == 1)
        #expect(try rows[0].blob(named: "data") == large)

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("text with embedded NUL-like markers and emoji round-trips without truncation")
    func unicodeAndEmbeddedMarkerTextRoundTrips() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let payload = "header\\0middle section with unicode \u{00E9}\u{4E2D}\u{6587} and emoji \u{1F680}\u{1F4E6} tail"
        try await database.write { writer in
            try writer.execute("CREATE TABLE note (id INTEGER PRIMARY KEY, content TEXT NOT NULL)")
            _ = try writer.mutate("INSERT INTO note (content) VALUES (?)", parameters: [.text(payload)])
        }

        let rows: [SQLiteRow] = try await database.read { reader in
            try reader.query("SELECT content FROM note")
        }
        #expect(rows.count == 1)
        #expect(try rows[0].text(named: "content") == payload)

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("a blob holding every byte value zero through two hundred fifty five round-trips exactly")
    func allByteValuesBlobRoundTrips() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let everyByte: [UInt8] = (0...255).map { UInt8($0) }
        try await database.write { writer in
            try writer.execute("CREATE TABLE raw (id INTEGER PRIMARY KEY, bytes BLOB NOT NULL)")
            _ = try writer.mutate("INSERT INTO raw (bytes) VALUES (?)", parameters: [.blob(everyByte)])
        }

        let rows: [SQLiteRow] = try await database.read { reader in
            try reader.query("SELECT bytes FROM raw")
        }
        #expect(rows.count == 1)
        let readBack = try rows[0].blob(named: "bytes")
        #expect(readBack == everyByte)
        #expect(readBack.count == 256)

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("an empty string reads back as empty text and is distinct from null")
    func emptyStringIsDistinctFromNull() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            try writer.execute("CREATE TABLE label (id INTEGER PRIMARY KEY, value TEXT)")
            _ = try writer.mutate("INSERT INTO label (id, value) VALUES (1, ?)", parameters: [.text("")])
            _ = try writer.mutate("INSERT INTO label (id, value) VALUES (2, ?)", parameters: [.null])
        }

        let rows: [SQLiteRow] = try await database.read { reader in
            try reader.query("SELECT value FROM label ORDER BY id ASC")
        }
        #expect(rows.count == 2)
        #expect(try rows[0].value(named: "value") == SQLiteValue.text(""))
        #expect(try rows[1].value(named: "value") == SQLiteValue.null)
        #expect(try rows[0].value(named: "value") != rows[1].value(named: "value"))

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("an empty blob reads back as an empty byte array")
    func emptyBlobReadsBackEmpty() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            try writer.execute("CREATE TABLE chunk (id INTEGER PRIMARY KEY, payload BLOB NOT NULL)")
            _ = try writer.mutate("INSERT INTO chunk (payload) VALUES (zeroblob(0))", parameters: [])
            _ = try writer.mutate("INSERT INTO chunk (payload) VALUES (X'')", parameters: [])
        }

        let rows: [SQLiteRow] = try await database.read { reader in
            try reader.query("SELECT payload FROM chunk ORDER BY id ASC")
        }
        #expect(rows.count == 2)
        #expect(try rows[0].value(named: "payload") == SQLiteValue.blob([]))
        #expect(try rows[1].value(named: "payload") == SQLiteValue.blob([]))

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("a select of a literal is reachable through an explicit alias")
    func literalSelectIsReachableByAlias() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let rows: [SQLiteRow] = try await database.read { reader in
            try reader.query("SELECT 1 AS literal_value")
        }
        #expect(rows.count == 1)
        #expect(try rows[0].integer(named: "literal_value") == 1)
        #expect(rows[0].columns.count == 1)
        #expect(try rows[0].columns[0].integer() == 1)

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("read stream over a valid query yields rows in order then finishes cleanly")
    func readStreamYieldsRowsInOrder() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.transaction { writer in
            try writer.execute("CREATE TABLE event (id INTEGER PRIMARY KEY, sortkey INTEGER NOT NULL)")
            for value in 0..<200 {
                _ = try writer.mutate("INSERT INTO event (sortkey) VALUES (?)", parameters: [.integer(Int64(value))])
            }
        }

        var collected: [Int64] = []
        for try await row in database.readStream("SELECT sortkey FROM event ORDER BY sortkey ASC") {
            collected.append(try row.integer(named: "sortkey"))
        }
        #expect(collected.count == 200)
        #expect(collected.first == 0)
        #expect(collected.last == 199)
        #expect(collected == (0..<200).map { Int64($0) })

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("read stream over invalid sql surfaces the error while iterating")
    func readStreamSurfacesInvalidSqlError() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        var threw = false
        do {
            for try await _ in database.readStream("SELECT FROM WHERE not valid sql") {
            }
        } catch {
            threw = true
        }
        #expect(threw)

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("value lookup for an absent column throws columnNotFound")
    func absentColumnThrowsColumnNotFound() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            try writer.execute("CREATE TABLE product (id INTEGER PRIMARY KEY, title TEXT NOT NULL)")
            _ = try writer.mutate("INSERT INTO product (title) VALUES (?)", parameters: [.text("widget")])
        }

        let rows: [SQLiteRow] = try await database.read { reader in
            try reader.query("SELECT title FROM product")
        }
        #expect(rows.count == 1)
        #expect(throws: SQLiteError.columnNotFound(name: "missing")) {
            _ = try rows[0].value(named: "missing")
        }

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }

    @Test("a typed accessor on a mismatched column throws valueTypeMismatch with expected and actual types")
    func mismatchedTypedAccessorThrowsValueTypeMismatch() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            try writer.execute("CREATE TABLE record (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
            _ = try writer.mutate("INSERT INTO record (name) VALUES (?)", parameters: [.text("gadget")])
        }

        let rows: [SQLiteRow] = try await database.read { reader in
            try reader.query("SELECT name FROM record")
        }
        #expect(rows.count == 1)
        #expect(throws: SQLiteError.valueTypeMismatch(expected: .integer, actual: .text)) {
            _ = try rows[0].integer(named: "name")
        }
        #expect(throws: SQLiteError.valueTypeMismatch(expected: .blob, actual: .text)) {
            _ = try rows[0].blob(named: "name")
        }

        await database.close()
        Self.removeTemporaryFiles(at: path)
    }
}
