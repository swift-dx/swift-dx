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

@Suite("DXSQLite writer decode and reader backup")
struct SQLiteWriterDecodeAndBackupTests {

    struct Item: Codable, Equatable {

        let id: Int64
        let name: String
    }

    static func makePath() -> String {
        NSTemporaryDirectory() + "dxsqlite-wdb-\(UUID().uuidString).sqlite"
    }

    static func removeFiles(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    @Test("the writer decodes its own query results into a Decodable type")
    func writerQueryAsDecodable() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let items = try await database.transaction { writer -> [Item] in
            try writer.execute("CREATE TABLE item (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
            _ = try writer.mutate("INSERT INTO item (id, name) VALUES (1, 'first')", parameters: [])
            _ = try writer.mutate("INSERT INTO item (id, name) VALUES (2, 'second')", parameters: [])
            return try writer.query("SELECT id, name FROM item ORDER BY id", as: Item.self)
        }
        #expect(items == [Item(id: 1, name: "first"), Item(id: 2, name: "second")])

        await database.close()
        Self.removeFiles(path)
    }

    @Test("a reader copies the live database to a new file via backup")
    func readerBackupToFile() async throws {
        let path = Self.makePath()
        let destination = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            try writer.execute("CREATE TABLE item (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
            _ = try writer.mutate("INSERT INTO item (id, name) VALUES (1, 'first')", parameters: [])
        }
        try await database.read { reader in
            try reader.backup(toFile: destination)
        }

        let copy = try await SQLite.connect(SQLiteConfiguration(location: .file(path: destination)))
        let count = try await copy.read { reader in
            try reader.query("SELECT count(*) AS n FROM item")[0].integer(named: "n")
        }
        #expect(count == 1)

        await copy.close()
        await database.close()
        Self.removeFiles(path)
        Self.removeFiles(destination)
    }

    @Test("a backup to an unreachable destination throws backupFailed")
    func backupToUnreachablePathThrows() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await database.write { writer in
            try writer.execute("CREATE TABLE item (id INTEGER PRIMARY KEY)")
        }

        await #expect(throws: SQLiteError.self) {
            try await database.write { writer in
                try writer.backup(toFile: "/dxsqlite-missing-root/nested/copy.sqlite")
            }
        }

        await database.close()
        Self.removeFiles(path)
    }
}
