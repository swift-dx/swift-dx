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

@Suite("DXSQLite edge cases")
struct SQLiteEdgeCaseTests {

    @Test("a NULL column reads as .null and rejects typed access")
    func nullHandling() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await database.write { writer in
            try writer.execute("CREATE TABLE t (v INTEGER)")
            _ = try writer.mutate("INSERT INTO t(v) VALUES (?)", parameters: [.null])
        }

        let rows = try await database.read { reader in try reader.query("SELECT v FROM t") }
        let row = try #require(rows.first)
        #expect(try row.value(named: "v") == .null)

        var rejected = false
        do {
            _ = try row.integer(named: "v")
        } catch {
            if case .valueTypeMismatch = error { rejected = true }
        }
        #expect(rejected)

        await database.close()
        Self.cleanUp(path)
    }

    @Test("reading an absent column throws columnNotFound")
    func columnNotFound() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await database.write { writer in
            try writer.execute("CREATE TABLE t (v INTEGER)")
            _ = try writer.mutate("INSERT INTO t(v) VALUES (1)", parameters: [])
        }

        let rows = try await database.read { reader in try reader.query("SELECT v FROM t") }
        let row = try #require(rows.first)

        var notFound = false
        do {
            _ = try row.value(named: "missing")
        } catch {
            if case .columnNotFound = error { notFound = true }
        }
        #expect(notFound)

        await database.close()
        Self.cleanUp(path)
    }

    @Test("invalid SQL surfaces executeFailed")
    func invalidSQL() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        var failed = false
        do {
            try await database.write { writer in
                try writer.execute("THIS IS NOT VALID SQL")
            }
        } catch let error as SQLiteError {
            if case .executeFailed = error { failed = true }
        }
        #expect(failed)

        await database.close()
        Self.cleanUp(path)
    }

    @Test("a large blob round-trips intact")
    func largeBlob() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        let payload = [UInt8](repeating: 0xAB, count: 64 * 1024)
        try await database.write { writer in
            try writer.execute("CREATE TABLE b (data BLOB)")
            _ = try writer.mutate("INSERT INTO b(data) VALUES (?)", parameters: [.blob(payload)])
        }

        let rows = try await database.read { reader in try reader.query("SELECT data FROM b") }
        let row = try #require(rows.first)
        #expect(try row.blob(named: "data") == payload)

        await database.close()
        Self.cleanUp(path)
    }

    @Test("concurrent writes serialize without losing updates")
    func writerSerialization() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await database.write { writer in
            try writer.execute("CREATE TABLE c (id INTEGER PRIMARY KEY, n INTEGER NOT NULL)")
            _ = try writer.mutate("INSERT INTO c(id, n) VALUES (1, 0)", parameters: [])
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    try await database.transaction { writer in
                        _ = try writer.mutate("UPDATE c SET n = n + 1 WHERE id = 1", parameters: [])
                    }
                }
            }
            try await group.waitForAll()
        }

        let rows = try await database.read { reader in try reader.query("SELECT n FROM c WHERE id = 1") }
        let row = try #require(rows.first)
        #expect(try row.integer(named: "n") == 50)

        await database.close()
        Self.cleanUp(path)
    }

    private static func makePath() -> String {
        NSTemporaryDirectory() + "dxsqlite-edge-\(UUID().uuidString).sqlite"
    }

    private static func cleanUp(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }
}
