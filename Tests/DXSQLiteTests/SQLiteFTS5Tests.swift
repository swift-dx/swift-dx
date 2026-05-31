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

@Suite("DXSQLite FTS5 full-text search")
struct SQLiteFTS5Tests {

    @Test("an FTS5 virtual table supports MATCH and rank through the SQL surface")
    func fullTextSearch() async throws {
        let path = NSTemporaryDirectory() + "dxsqlite-fts5-\(UUID().uuidString).sqlite"
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            try writer.execute("CREATE VIRTUAL TABLE docs USING fts5(title, body)")
            _ = try writer.mutate("INSERT INTO docs(title, body) VALUES ('Swift', 'a fast and safe systems language')", parameters: [])
            _ = try writer.mutate("INSERT INTO docs(title, body) VALUES ('SQLite', 'an embedded database engine')", parameters: [])
        }

        let rows = try await database.read { reader in
            try reader.query("SELECT title FROM docs WHERE docs MATCH ? ORDER BY rank", parameters: [.text("database")])
        }
        #expect(rows.count == 1)
        #expect(try #require(rows.first).text(named: "title") == "SQLite")

        await database.close()
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }
}
