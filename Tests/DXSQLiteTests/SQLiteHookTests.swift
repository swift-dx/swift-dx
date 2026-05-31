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
import Synchronization
import Testing
import DXSQLite

@Suite("DXSQLite write hooks")
struct SQLiteHookTests {

    final class ChangeRecorder: Sendable {

        private let storage = Mutex<[SQLiteChange]>([])

        func record(_ change: SQLiteChange) {
            storage.withLock { $0.append(change) }
        }

        func snapshot() -> [SQLiteChange] {
            storage.withLock { $0 }
        }
    }

    @Test("the update hook observes inserts, updates, and deletes")
    func updateHook() async throws {
        let path = NSTemporaryDirectory() + "dxsqlite-hook-\(UUID().uuidString).sqlite"
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        let recorder = ChangeRecorder()
        await database.observeUpdates { change in recorder.record(change) }

        try await database.write { writer in
            try writer.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)")
            _ = try writer.mutate("INSERT INTO t(id, v) VALUES (1, 10)", parameters: [])
            _ = try writer.mutate("UPDATE t SET v = 20 WHERE id = 1", parameters: [])
            _ = try writer.mutate("DELETE FROM t WHERE id = 1", parameters: [])
        }

        let changes = recorder.snapshot()
        #expect(changes.map(\.operation) == [.insert, .update, .delete])
        #expect(changes.allSatisfy { $0.tableName == "t" })

        await database.close()
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }
}
