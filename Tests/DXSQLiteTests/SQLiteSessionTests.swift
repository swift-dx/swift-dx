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

@Suite("DXSQLite sessions and changesets")
struct SQLiteSessionTests {

    @Test("a changeset captures writes on one database and applies to another")
    func changesetRoundTrip() async throws {
        let sourcePath = NSTemporaryDirectory() + "dxsqlite-sess-a-\(UUID().uuidString).sqlite"
        let targetPath = NSTemporaryDirectory() + "dxsqlite-sess-b-\(UUID().uuidString).sqlite"
        let source = try await SQLite.connect(SQLiteConfiguration(location: .file(path: sourcePath)))
        let target = try await SQLite.connect(SQLiteConfiguration(location: .file(path: targetPath)))

        for database in [source, target] {
            try await database.write { writer in
                try writer.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER NOT NULL)")
            }
        }

        let changeset = try await source.write { writer in
            try writer.recordingChangeset { recording in
                _ = try recording.mutate("INSERT INTO t(id, v) VALUES (1, 100)", parameters: [])
                _ = try recording.mutate("INSERT INTO t(id, v) VALUES (2, 200)", parameters: [])
            }
        }
        #expect(changeset.count > 0)

        try await target.write { writer in
            try writer.applyChangeset(changeset)
        }

        let rows = try await target.read { reader in
            try reader.query("SELECT v FROM t ORDER BY id")
        }
        #expect(rows.count == 2)
        #expect(try rows[0].integer(named: "v") == 100)
        #expect(try rows[1].integer(named: "v") == 200)

        await source.close()
        await target.close()
        for candidate in [sourcePath, targetPath] {
            try? FileManager.default.removeItem(atPath: candidate)
            try? FileManager.default.removeItem(atPath: candidate + "-wal")
            try? FileManager.default.removeItem(atPath: candidate + "-shm")
        }
    }
}
