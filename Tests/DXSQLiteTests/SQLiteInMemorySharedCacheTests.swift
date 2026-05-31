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

@Suite("DXSQLite in-memory shared cache")
struct SQLiteInMemorySharedCacheTests {

    static let tempPrefix = "dxsqlite-memshare"

    static func makeName() -> String {
        "\(tempPrefix)-\(UUID().uuidString)"
    }

    static func seedSessions(_ database: SQLiteDatabase, rowCount: Int) async throws {
        try await database.write { writer in
            try writer.execute("CREATE TABLE session (id INTEGER PRIMARY KEY, token TEXT NOT NULL, weight REAL NOT NULL)")
            for index in 0..<rowCount {
                _ = try writer.mutate(
                    "INSERT INTO session(id, token, weight) VALUES (?, ?, ?)",
                    parameters: [.integer(Int64(index + 1)), .text("TOKEN-\(index + 1)"), .real(Double(index + 1) * 0.25)]
                )
            }
        }
    }

    static func countSessions(_ database: SQLiteDatabase) async throws -> Int {
        try await database.read { reader in
            let rows = try reader.query("SELECT COUNT(*) AS total FROM session")
            let total = try rows[0].integer(named: "total")
            return Int(total)
        }
    }

    @Test("a single in-memory database reads back rows written through a prior write call")
    func writeThenReadAcrossSeparateCalls() async throws {
        let name = Self.makeName()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .inMemory(name: name), maxReaders: 2))

        try await Self.seedSessions(database, rowCount: 6)

        let total = try await Self.countSessions(database)
        #expect(total == 6)

        let firstToken = try await database.read { reader in
            let rows = try reader.query("SELECT token FROM session WHERE id = ?", parameters: [.integer(1)])
            return try rows[0].text(named: "token")
        }
        #expect(firstToken == "TOKEN-1")

        let weightSum = try await database.read { reader in
            let rows = try reader.query("SELECT SUM(weight) AS total FROM session")
            return try rows[0].double(named: "total")
        }
        #expect(weightSum == 5.25)

        await database.close()
    }

    @Test("concurrent readers all observe rows committed before they start")
    func concurrentReadersObservePriorWrites() async throws {
        let name = Self.makeName()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .inMemory(name: name), maxReaders: 4))

        try await Self.seedSessions(database, rowCount: 9)

        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    try await Self.countSessions(database)
                }
            }
            var collected: [Int] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        #expect(results.count == 40)
        #expect(results.allSatisfy { $0 == 9 })

        await database.close()
    }

    @Test("two databases on the same in-memory name share data")
    func sameNameSharesData() async throws {
        let name = Self.makeName()
        let writerDatabase = try await SQLite.connect(SQLiteConfiguration(location: .inMemory(name: name), maxReaders: 2))
        let observerDatabase = try await SQLite.connect(SQLiteConfiguration(location: .inMemory(name: name), maxReaders: 2))

        try await Self.seedSessions(writerDatabase, rowCount: 4)

        let observedTotal = try await Self.countSessions(observerDatabase)
        #expect(observedTotal == 4)

        let observedToken = try await observerDatabase.read { reader in
            let rows = try reader.query("SELECT token FROM session WHERE id = ?", parameters: [.integer(3)])
            return try rows[0].text(named: "token")
        }
        #expect(observedToken == "TOKEN-3")

        await writerDatabase.close()
        await observerDatabase.close()
    }

    @Test("two databases on different in-memory names are isolated")
    func differentNamesAreIsolated() async throws {
        let firstName = Self.makeName()
        let secondName = Self.makeName()
        let firstDatabase = try await SQLite.connect(SQLiteConfiguration(location: .inMemory(name: firstName), maxReaders: 2))
        let secondDatabase = try await SQLite.connect(SQLiteConfiguration(location: .inMemory(name: secondName), maxReaders: 2))

        try await Self.seedSessions(firstDatabase, rowCount: 5)
        try await secondDatabase.write { writer in
            try writer.execute("CREATE TABLE session (id INTEGER PRIMARY KEY, token TEXT NOT NULL, weight REAL NOT NULL)")
        }

        let firstTotal = try await Self.countSessions(firstDatabase)
        #expect(firstTotal == 5)

        let secondTotal = try await Self.countSessions(secondDatabase)
        #expect(secondTotal == 0)

        await #expect(throws: SQLiteError.self) {
            _ = try await firstDatabase.read { reader in
                try reader.query("SELECT id FROM nonexistent_table")
            }
        }

        await firstDatabase.close()
        await secondDatabase.close()
    }

    @Test("concurrent transactions on an in-memory database land the exact counter total")
    func concurrentTransactionsSerializeToExactTotal() async throws {
        let name = Self.makeName()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .inMemory(name: name), maxReaders: 4))

        try await database.write { writer in
            try writer.execute("CREATE TABLE counter (id INTEGER PRIMARY KEY, total INTEGER NOT NULL)")
            _ = try writer.mutate("INSERT INTO counter(id, total) VALUES (1, 0)", parameters: [])
        }

        let incrementCount = 200
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<incrementCount {
                group.addTask {
                    try await database.transaction { writer in
                        let rows = try writer.query("SELECT total FROM counter WHERE id = 1")
                        let current = try rows[0].integer(named: "total")
                        _ = try writer.mutate(
                            "UPDATE counter SET total = ? WHERE id = 1",
                            parameters: [.integer(current + 1)]
                        )
                    }
                }
            }
            for try await _ in group {
            }
        }

        let total = try await database.read { reader in
            let rows = try reader.query("SELECT total FROM counter WHERE id = 1")
            let value = try rows[0].integer(named: "total")
            return Int(value)
        }
        #expect(total == incrementCount)

        await database.close()
    }
}
