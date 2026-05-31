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

@Suite("DXSQLite error recovery")
struct SQLiteErrorRecoveryTests {

    static let tempPrefix = "dxsqlite-recover"

    struct InjectedFailure: Error {}

    static func makePath() -> String {
        NSTemporaryDirectory() + "\(tempPrefix)-\(UUID().uuidString).sqlite"
    }

    static func removeFiles(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    static func seedAccounts(_ database: SQLiteDatabase) async throws {
        try await database.write { writer in
            try writer.execute("CREATE TABLE account (id INTEGER PRIMARY KEY, owner TEXT NOT NULL UNIQUE, balance INTEGER NOT NULL)")
            _ = try writer.mutate(
                "INSERT INTO account(id, owner, balance) VALUES (?, ?, ?)",
                parameters: [.integer(1), .text("alpha"), .integer(100)]
            )
        }
    }

    static func balance(of owner: String, in database: SQLiteDatabase) async throws -> Int {
        try await database.read { reader in
            let rows = try reader.query("SELECT balance FROM account WHERE owner = ?", parameters: [.text(owner)])
            return Int(try rows[0].integer(named: "balance"))
        }
    }

    static func accountCount(_ database: SQLiteDatabase) async throws -> Int {
        try await database.read { reader in
            let rows = try reader.query("SELECT COUNT(*) AS total FROM account")
            return Int(try rows[0].integer(named: "total"))
        }
    }

    @Test("a thrown transaction rolls back and the next write commits and is visible")
    func thrownTransactionRollsBackThenNextWriteSucceeds() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await Self.seedAccounts(database)

        await #expect(throws: Self.InjectedFailure.self) {
            try await database.transaction { writer in
                _ = try writer.mutate(
                    "UPDATE account SET balance = ? WHERE owner = ?",
                    parameters: [.integer(999), .text("alpha")]
                )
                throw Self.InjectedFailure()
            }
        }

        let afterRollback = try await Self.balance(of: "alpha", in: database)
        #expect(afterRollback == 100)

        try await database.write { writer in
            _ = try writer.mutate(
                "UPDATE account SET balance = ? WHERE owner = ?",
                parameters: [.integer(250), .text("alpha")]
            )
        }

        let afterCommit = try await Self.balance(of: "alpha", in: database)
        #expect(afterCommit == 250)

        await database.close()
        Self.removeFiles(path)
    }

    @Test("a constraint violation in a transaction rolls back and the next write commits")
    func constraintViolationRollsBackThenNextWriteSucceeds() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await Self.seedAccounts(database)

        await #expect(throws: SQLiteError.self) {
            try await database.transaction { writer in
                _ = try writer.mutate(
                    "UPDATE account SET balance = ? WHERE owner = ?",
                    parameters: [.integer(500), .text("alpha")]
                )
                _ = try writer.mutate(
                    "INSERT INTO account(id, owner, balance) VALUES (?, ?, ?)",
                    parameters: [.integer(2), .text("alpha"), .integer(0)]
                )
            }
        }

        let afterRollback = try await Self.balance(of: "alpha", in: database)
        #expect(afterRollback == 100)

        let count = try await Self.accountCount(database)
        #expect(count == 1)

        try await database.write { writer in
            _ = try writer.mutate(
                "INSERT INTO account(id, owner, balance) VALUES (?, ?, ?)",
                parameters: [.integer(2), .text("beta"), .integer(42)]
            )
        }

        let betaBalance = try await Self.balance(of: "beta", in: database)
        #expect(betaBalance == 42)

        await database.close()
        Self.removeFiles(path)
    }

    @Test("an invalid read throws and the next read reuses the pool successfully")
    func invalidReadThrowsThenNextReadSucceeds() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 1))
        try await Self.seedAccounts(database)

        await #expect(throws: SQLiteError.self) {
            _ = try await database.read { reader in
                try reader.query("SELECT * FROM nonexistent_table")
            }
        }

        let balance = try await Self.balance(of: "alpha", in: database)
        #expect(balance == 100)

        let reuseChecks = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    try await Self.accountCount(database)
                }
            }
            var collected: [Int] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        #expect(reuseChecks.count == 16)
        #expect(reuseChecks.allSatisfy { $0 == 1 })

        await database.close()
        Self.removeFiles(path)
    }

    @Test("a failed write throws yet lastInsertRowID and later inserts stay correct")
    func failedWriteThrowsThenInsertsStayCorrect() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            try writer.execute("CREATE TABLE event (id INTEGER PRIMARY KEY AUTOINCREMENT, label TEXT NOT NULL)")
            _ = try writer.mutate("INSERT INTO event(label) VALUES (?)", parameters: [.text("first")])
        }

        await #expect(throws: SQLiteError.self) {
            try await database.write { writer in
                try writer.execute("INSRT INTO event(label) VALUES ('broken')")
            }
        }

        let recovered = try await database.write { writer in
            _ = try writer.mutate("INSERT INTO event(label) VALUES (?)", parameters: [.text("second")])
            let secondRowID = writer.lastInsertRowID
            _ = try writer.mutate("INSERT INTO event(label) VALUES (?)", parameters: [.text("third")])
            let thirdRowID = writer.lastInsertRowID
            return [secondRowID, thirdRowID]
        }

        #expect(recovered == [2, 3])

        let total = try await database.read { reader in
            let rows = try reader.query("SELECT COUNT(*) AS total FROM event")
            return Int(try rows[0].integer(named: "total"))
        }
        #expect(total == 3)

        await database.close()
        Self.removeFiles(path)
    }

    @Test("one hundred alternating success and failure operations leave only successes")
    func alternatingSuccessFailureLeavesExpectedRows() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await database.write { writer in
            try writer.execute("CREATE TABLE item (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
        }

        var expectedSuccesses = 0
        for index in 0..<100 {
            if index % 2 == 1 {
                await #expect(throws: SQLiteError.self) {
                    try await database.write { writer in
                        try writer.execute("INSERT INTO item(id, name) VALUES (\(index), bad_column_reference)")
                    }
                }
            } else {
                try await database.write { writer in
                    _ = try writer.mutate(
                        "INSERT INTO item(id, name) VALUES (?, ?)",
                        parameters: [.integer(Int64(index)), .text("item-\(index)")]
                    )
                }
                expectedSuccesses += 1
            }
        }

        let total = try await database.read { reader in
            let rows = try reader.query("SELECT COUNT(*) AS total FROM item")
            return Int(try rows[0].integer(named: "total"))
        }
        #expect(expectedSuccesses == 50)
        #expect(total == 50)

        let maxID = try await database.read { reader in
            let rows = try reader.query("SELECT MAX(id) AS top FROM item")
            return Int(try rows[0].integer(named: "top"))
        }
        #expect(maxID == 98)

        await database.close()
        Self.removeFiles(path)
    }

    @Test("a unique violation in a transaction can be retried with a corrected value")
    func uniqueViolationRetrySucceeds() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await Self.seedAccounts(database)

        await #expect(throws: SQLiteError.self) {
            try await database.transaction { writer in
                _ = try writer.mutate(
                    "INSERT INTO account(id, owner, balance) VALUES (?, ?, ?)",
                    parameters: [.integer(2), .text("alpha"), .integer(70)]
                )
            }
        }

        let afterFailure = try await Self.accountCount(database)
        #expect(afterFailure == 1)

        try await database.transaction { writer in
            _ = try writer.mutate(
                "INSERT INTO account(id, owner, balance) VALUES (?, ?, ?)",
                parameters: [.integer(2), .text("gamma"), .integer(70)]
            )
        }

        let afterRetry = try await Self.accountCount(database)
        #expect(afterRetry == 2)

        let gammaBalance = try await Self.balance(of: "gamma", in: database)
        #expect(gammaBalance == 70)

        let alphaBalance = try await Self.balance(of: "alpha", in: database)
        #expect(alphaBalance == 100)

        await database.close()
        Self.removeFiles(path)
    }
}
