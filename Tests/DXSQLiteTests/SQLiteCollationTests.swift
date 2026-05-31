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

@Suite("DXSQLite custom collations")
struct SQLiteCollationTests {

    @Test("a custom collation orders results on a pooled reader")
    func collation() async throws {
        let caseInsensitive = SQLiteCollation(name: "ci") { left, right in
            left.lowercased().compare(right.lowercased())
        }
        let path = NSTemporaryDirectory() + "dxsqlite-coll-\(UUID().uuidString).sqlite"
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), collations: [caseInsensitive]))

        try await database.write { writer in
            try writer.execute("CREATE TABLE t (name TEXT NOT NULL)")
            for name in ["banana", "Apple", "cherry", "apple"] {
                _ = try writer.mutate("INSERT INTO t(name) VALUES (?)", parameters: [.text(name)])
            }
        }

        let rows = try await database.read { reader in
            try reader.query("SELECT name FROM t ORDER BY name COLLATE ci, name")
        }
        var names: [String] = []
        for row in rows {
            names.append(try row.text(named: "name"))
        }
        #expect(names == ["Apple", "apple", "banana", "cherry"])

        await database.close()
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }
}
