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

@Suite("DXSQLite hooks and observers")
struct SQLiteHookObserverTests {

    final class InvocationCounter: Sendable {

        private let storage = Mutex<Int>(0)

        func increment() {
            storage.withLock { $0 += 1 }
        }

        var value: Int {
            storage.withLock { $0 }
        }
    }

    final class ChangeLog: Sendable {

        private let storage = Mutex<[SQLiteChange]>([])

        func append(_ change: SQLiteChange) {
            storage.withLock { $0.append(change) }
        }

        var snapshot: [SQLiteChange] {
            storage.withLock { $0 }
        }
    }

    final class AbortingProgressGate: Sendable {

        private let calls = Mutex<Int>(0)
        private let limit: Int

        init(allowedCalls: Int) {
            self.limit = allowedCalls
        }

        func shouldContinue() -> Bool {
            calls.withLock { current in
                current += 1
                return current <= limit
            }
        }

        var callCount: Int {
            calls.withLock { $0 }
        }
    }

    static func temporaryPath() -> String {
        NSTemporaryDirectory() + "dxsqlite-hookobs-\(UUID().uuidString).sqlite"
    }

    static func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    @Test("the commit hook fires once per committed transaction")
    func commitHookCountsTransactions() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            try writer.execute("CREATE TABLE ledger (id INTEGER PRIMARY KEY, amount INTEGER NOT NULL)")
        }

        let counter = InvocationCounter()
        try await database.observeCommits { counter.increment() }

        for value in 1...3 {
            try await database.transaction { writer in
                _ = try writer.mutate("INSERT INTO ledger (amount) VALUES (?1)", parameters: [.integer(Int64(value * 10))])
            }
        }

        #expect(counter.value == 3)

        let total = try await database.read { reader in
            try reader.query("SELECT COUNT(*) AS n FROM ledger")
        }
        #expect(try total[0].integer(named: "n") == 3)

        await database.close()
        Self.remove(path)
    }

    @Test("the rollback hook fires when a transaction body throws")
    func rollbackHookFiresOnThrownBody() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            try writer.execute("CREATE TABLE account (id INTEGER PRIMARY KEY, balance INTEGER NOT NULL)")
            _ = try writer.mutate("INSERT INTO account (id, balance) VALUES (1, 500)", parameters: [])
        }

        let counter = InvocationCounter()
        try await database.observeRollbacks { counter.increment() }

        struct DeliberateFailure: Error {}

        await #expect(throws: DeliberateFailure.self) {
            try await database.transaction { writer in
                _ = try writer.mutate("UPDATE account SET balance = 0 WHERE id = 1", parameters: [])
                throw DeliberateFailure()
            }
        }

        #expect(counter.value == 1)

        let rows = try await database.read { reader in
            try reader.query("SELECT balance FROM account WHERE id = 1")
        }
        #expect(try rows[0].integer(named: "balance") == 500)

        await database.close()
        Self.remove(path)
    }

    @Test("the update hook reports operation, table name, and rowid per mutation")
    func updateHookReportsEachMutation() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let log = ChangeLog()
        try await database.observeUpdates { change in log.append(change) }

        try await database.write { writer in
            try writer.execute("CREATE TABLE product (id INTEGER PRIMARY KEY, name TEXT NOT NULL, stock INTEGER NOT NULL)")
            _ = try writer.mutate("INSERT INTO product (id, name, stock) VALUES (1, 'widget', 5)", parameters: [])
            _ = try writer.mutate("INSERT INTO product (id, name, stock) VALUES (2, 'gadget', 9)", parameters: [])
            _ = try writer.mutate("UPDATE product SET stock = 4 WHERE id = 1", parameters: [])
            _ = try writer.mutate("DELETE FROM product WHERE id = 2", parameters: [])
        }

        let changes = log.snapshot
        #expect(changes.count == 4)
        #expect(changes.map(\.operation) == [.insert, .insert, .update, .delete])
        #expect(changes.allSatisfy { $0.tableName == "product" })
        #expect(changes[0].rowID == 1)
        #expect(changes[1].rowID == 2)
        #expect(changes[2].rowID == 1)
        #expect(changes[3].rowID == 2)

        await database.close()
        Self.remove(path)
    }

    @Test("the update hook produces one call per affected row in a multi-row mutation")
    func updateHookCountsMultipleRowMutations() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            try writer.execute("CREATE TABLE item (id INTEGER PRIMARY KEY, price INTEGER NOT NULL)")
            for identifier in 1...4 {
                _ = try writer.mutate("INSERT INTO item (id, price) VALUES (?1, ?2)", parameters: [.integer(Int64(identifier)), .integer(100)])
            }
        }

        let log = ChangeLog()
        try await database.observeUpdates { change in log.append(change) }

        let affected = try await database.write { writer in
            try writer.mutate("UPDATE item SET price = price + 50", parameters: [])
        }
        #expect(affected == 4)

        let changes = log.snapshot
        #expect(changes.count == 4)
        #expect(changes.allSatisfy { $0.operation == .update })
        #expect(changes.allSatisfy { $0.tableName == "item" })
        #expect(Set(changes.map(\.rowID)) == Set<Int64>([1, 2, 3, 4]))

        await database.close()
        Self.remove(path)
    }

    @Test("the progress observer is invoked and aborting it fails the running query")
    func progressObserverAbortsQuery() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            try writer.execute("CREATE TABLE big (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)")
            try writer.execute("BEGIN")
            for identifier in 1...500 {
                _ = try writer.mutate("INSERT INTO big (id, value) VALUES (?1, ?2)", parameters: [.integer(Int64(identifier)), .integer(Int64(identifier))])
            }
            try writer.execute("COMMIT")
        }

        let gate = AbortingProgressGate(allowedCalls: 2)
        try await database.observeProgress(everyInstructions: 1) { gate.shouldContinue() }

        await #expect(throws: SQLiteError.self) {
            try await database.write { writer in
                _ = try writer.query("SELECT SUM(a.value * b.value) AS total FROM big a, big b")
            }
        }

        #expect(gate.callCount > 0)

        await database.close()
        Self.remove(path)
    }

    @Test("a write succeeds with a busy observer installed")
    func busyObserverPermitsNormalWrites() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.observeBusy { _ in true }

        try await database.write { writer in
            try writer.execute("CREATE TABLE customer (id INTEGER PRIMARY KEY, email TEXT NOT NULL)")
            _ = try writer.mutate("INSERT INTO customer (id, email) VALUES (1, 'buyer@example.com')", parameters: [])
        }

        let rows = try await database.read { reader in
            try reader.query("SELECT email FROM customer WHERE id = 1")
        }
        #expect(rows.count == 1)
        #expect(try rows[0].text(named: "email") == "buyer@example.com")

        await database.close()
        Self.remove(path)
    }
}
