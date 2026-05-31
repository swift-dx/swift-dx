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

@Suite("DXSQLite transactions")
struct SQLiteTransactionTests {

    struct AbortSignal: Error {}

    @Test("a transaction commits every write in it")
    func commits() async throws {
        let path = NSTemporaryDirectory() + "dxsqlite-\(UUID().uuidString).sqlite"
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await seedAccount(database)

        try await database.transaction { writer in
            _ = try writer.mutate("UPDATE acct SET balance = balance - 10 WHERE id = 1", parameters: [])
            _ = try writer.mutate("UPDATE acct SET balance = balance - 5 WHERE id = 1", parameters: [])
        }

        #expect(try await balance(of: database) == 85)
        await database.close()
        Self.cleanUp(path)
    }

    @Test("a throwing transaction rolls back every write in it")
    func rollsBack() async throws {
        let path = NSTemporaryDirectory() + "dxsqlite-\(UUID().uuidString).sqlite"
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await seedAccount(database)

        await #expect(throws: AbortSignal.self) {
            try await database.transaction { writer in
                _ = try writer.mutate("UPDATE acct SET balance = balance - 50 WHERE id = 1", parameters: [])
                throw AbortSignal()
            }
        }

        #expect(try await balance(of: database) == 100)
        await database.close()
        Self.cleanUp(path)
    }

    private func seedAccount(_ database: SQLiteDatabase) async throws {
        try await database.write { writer in
            try writer.execute("CREATE TABLE acct (id INTEGER PRIMARY KEY, balance INTEGER NOT NULL)")
            _ = try writer.mutate("INSERT INTO acct(id, balance) VALUES (1, 100)", parameters: [])
        }
    }

    private func balance(of database: SQLiteDatabase) async throws -> Int64 {
        let rows = try await database.read { reader in
            try reader.query("SELECT balance FROM acct WHERE id = 1")
        }
        guard case .integer(let value) = try rows[0].value(named: "balance") else { return -1 }
        return value
    }

    private static func cleanUp(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }
}
