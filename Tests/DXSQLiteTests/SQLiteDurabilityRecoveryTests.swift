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

@Suite("DXSQLite durability and recovery")
struct SQLiteDurabilityRecoveryTests {

    static let tempPrefix = "dxsqlite-durab"

    static func makePath() -> String {
        NSTemporaryDirectory() + "\(tempPrefix)-\(UUID().uuidString).sqlite"
    }

    static func makeMemoryName() -> String {
        "\(tempPrefix)-\(UUID().uuidString)"
    }

    static func removeFiles(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    static func seedAccounts(_ database: SQLiteDatabase, rowCount: Int) async throws {
        try await database.write { writer in
            try writer.execute("CREATE TABLE account (id INTEGER PRIMARY KEY, owner TEXT NOT NULL, balance INTEGER NOT NULL)")
            for index in 0..<rowCount {
                _ = try writer.mutate(
                    "INSERT INTO account(id, owner, balance) VALUES (?, ?, ?)",
                    parameters: [.integer(Int64(index + 1)), .text("owner-\(index + 1)"), .integer(Int64((index + 1) * 100))]
                )
            }
        }
    }

    static func countAccounts(_ database: SQLiteDatabase) async throws -> Int {
        try await database.read { reader in
            let rows = try reader.query("SELECT COUNT(*) AS total FROM account")
            let total = try rows[0].integer(named: "total")
            return Int(total)
        }
    }

    static func balanceSum(_ database: SQLiteDatabase) async throws -> Int {
        try await database.read { reader in
            let rows = try reader.query("SELECT COALESCE(SUM(balance), 0) AS sum FROM account")
            let sum = try rows[0].integer(named: "sum")
            return Int(sum)
        }
    }

    @Test("rows written then committed survive a full close and reopen on the same file")
    func writesPersistAcrossReopen() async throws {
        let path = Self.makePath()

        let firstOpen = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await Self.seedAccounts(firstOpen, rowCount: 64)
        let writtenCount = try await Self.countAccounts(firstOpen)
        let writtenSum = try await Self.balanceSum(firstOpen)
        #expect(writtenCount == 64)
        await firstOpen.close()

        let secondOpen = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        let recoveredCount = try await Self.countAccounts(secondOpen)
        let recoveredSum = try await Self.balanceSum(secondOpen)
        #expect(recoveredCount == 64)
        #expect(recoveredSum == writtenSum)

        let sampled = try await secondOpen.read { reader in
            let rows = try reader.query("SELECT owner, balance FROM account WHERE id = ?", parameters: [.integer(7)])
            let owner = try rows[0].text(named: "owner")
            let balance = try rows[0].integer(named: "balance")
            return [owner, String(balance)]
        }
        #expect(sampled == ["owner-7", "700"])

        await secondOpen.close()
        Self.removeFiles(path)
    }

    @Test("full synchronous committed data survives a close and reopen")
    func fullSynchronousWritesPersistAcrossReopen() async throws {
        let path = Self.makePath()
        let durableConfiguration = SQLiteConfiguration(location: .file(path: path), tuning: SQLiteTuning(synchronous: .full))

        let firstOpen = try await SQLite.connect(durableConfiguration)
        try await Self.seedAccounts(firstOpen, rowCount: 40)
        let writtenSum = try await Self.balanceSum(firstOpen)
        await firstOpen.close()

        let secondOpen = try await SQLite.connect(durableConfiguration)
        let recoveredCount = try await Self.countAccounts(secondOpen)
        let recoveredSum = try await Self.balanceSum(secondOpen)
        let synchronousLevel = try await secondOpen.read { reader in
            let rows = try reader.query("PRAGMA synchronous")
            return try rows[0].integer(named: "synchronous")
        }
        #expect(recoveredCount == 40)
        #expect(recoveredSum == writtenSum)
        #expect(synchronousLevel == 2)

        await secondOpen.close()
        Self.removeFiles(path)
    }

    @Test("a committed transaction is durable while a rolled-back one leaves no trace")
    func committedTransactionDurableRolledBackAbsent() async throws {
        let path = Self.makePath()

        let firstOpen = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await firstOpen.write { writer in
            try writer.execute("CREATE TABLE entry (id INTEGER PRIMARY KEY, label TEXT NOT NULL)")
        }

        try await firstOpen.transaction { writer in
            _ = try writer.mutate("INSERT INTO entry(id, label) VALUES (?, ?)", parameters: [.integer(1), .text("committed-one")])
            _ = try writer.mutate("INSERT INTO entry(id, label) VALUES (?, ?)", parameters: [.integer(2), .text("committed-two")])
        }

        await #expect(throws: SQLiteError.self) {
            try await firstOpen.transaction { writer in
                _ = try writer.mutate("INSERT INTO entry(id, label) VALUES (?, ?)", parameters: [.integer(3), .text("doomed-three")])
                try writer.execute("INSERT INTO entry(id, label) VALUES (1, 'duplicate-primary-key')")
            }
        }
        await firstOpen.close()

        let secondOpen = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        let labels = try await secondOpen.read { reader in
            let rows = try reader.query("SELECT label FROM entry ORDER BY id")
            var collected: [String] = []
            for row in rows {
                collected.append(try row.text(named: "label"))
            }
            return collected
        }
        #expect(labels == ["committed-one", "committed-two"])

        let doomedPresent = try await secondOpen.read { reader in
            let rows = try reader.query("SELECT COUNT(*) AS total FROM entry WHERE label = ?", parameters: [.text("doomed-three")])
            return try rows[0].integer(named: "total")
        }
        #expect(doomedPresent == 0)

        await secondOpen.close()
        Self.removeFiles(path)
    }

    @Test("the same file reopened with a different reader count still reads every row")
    func reopenWithDifferentMaxReaders() async throws {
        let path = Self.makePath()

        let firstOpen = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 2))
        try await Self.seedAccounts(firstOpen, rowCount: 30)
        await firstOpen.close()

        let secondOpen = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 8))
        let counts = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    try await Self.countAccounts(secondOpen)
                }
            }
            var collected: [Int] = []
            for try await count in group {
                collected.append(count)
            }
            return collected
        }
        #expect(counts.count == 24)
        #expect(counts.allSatisfy { $0 == 30 })

        await secondOpen.close()
        Self.removeFiles(path)
    }

    @Test("an in-memory database shares its rows with a second handle on the same name but is gone after close")
    func inMemorySharedCacheLivenessThenLost() async throws {
        let name = Self.makeMemoryName()

        let keepAlive = try await SQLite.connect(SQLiteConfiguration(location: .inMemory(name: name)))
        try await Self.seedAccounts(keepAlive, rowCount: 16)
        let writtenCount = try await Self.countAccounts(keepAlive)
        #expect(writtenCount == 16)

        let secondHandle = try await SQLite.connect(SQLiteConfiguration(location: .inMemory(name: name)))
        let sharedCount = try await Self.countAccounts(secondHandle)
        #expect(sharedCount == 16)
        await secondHandle.close()

        let stillAliveCount = try await Self.countAccounts(keepAlive)
        #expect(stillAliveCount == 16)
        await keepAlive.close()

        let reopened = try await SQLite.connect(SQLiteConfiguration(location: .inMemory(name: name)))
        await #expect(throws: SQLiteError.self) {
            _ = try await reopened.read { reader in
                try reader.query("SELECT COUNT(*) AS total FROM account")
            }
        }
        await reopened.close()
    }
}
