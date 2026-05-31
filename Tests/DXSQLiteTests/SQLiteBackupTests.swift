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

@Suite("DXSQLite backup")
struct SQLiteBackupTests {

    @Test("backup copies the live database into a new file")
    func backup() async throws {
        let sourcePath = NSTemporaryDirectory() + "dxsqlite-src-\(UUID().uuidString).sqlite"
        let backupPath = NSTemporaryDirectory() + "dxsqlite-bak-\(UUID().uuidString).sqlite"

        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: sourcePath)))
        try await database.write { writer in
            try writer.execute("CREATE TABLE t (v INTEGER NOT NULL)")
            _ = try writer.mutate("INSERT INTO t(v) VALUES (42)", parameters: [])
            try writer.backup(toFile: backupPath)
        }
        await database.close()

        let restored = try await SQLite.connect(SQLiteConfiguration(location: .file(path: backupPath)))
        let rows = try await restored.read { reader in
            try reader.query("SELECT v FROM t")
        }
        #expect(try #require(rows.first).integer(named: "v") == 42)
        await restored.close()

        for candidate in [sourcePath, backupPath] {
            try? FileManager.default.removeItem(atPath: candidate)
            try? FileManager.default.removeItem(atPath: candidate + "-wal")
            try? FileManager.default.removeItem(atPath: candidate + "-shm")
        }
    }
}
