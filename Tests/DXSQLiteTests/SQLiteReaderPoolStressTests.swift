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

@Suite("DXSQLite reader pool stress")
struct SQLiteReaderPoolStressTests {

    static let tempPrefix = "dxsqlite-poolstress"

    static func makePath() -> String {
        NSTemporaryDirectory() + "\(tempPrefix)-\(UUID().uuidString).sqlite"
    }

    static func removeFiles(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    static func seedCatalog(_ database: SQLiteDatabase, rowCount: Int) async throws {
        try await database.write { writer in
            try writer.execute("CREATE TABLE product (id INTEGER PRIMARY KEY, sku TEXT NOT NULL, price REAL NOT NULL)")
            for index in 0..<rowCount {
                _ = try writer.mutate(
                    "INSERT INTO product(id, sku, price) VALUES (?, ?, ?)",
                    parameters: [.integer(Int64(index + 1)), .text("SKU-\(index + 1)"), .real(Double(index + 1) * 1.5)]
                )
            }
        }
    }

    static func countProducts(_ database: SQLiteDatabase) async throws -> Int {
        try await database.read { reader in
            let rows = try reader.query("SELECT COUNT(*) AS total FROM product")
            return Int(try rows[0].integer(named: "total"))
        }
    }

    @Test("a single reader serializes fifty concurrent reads to correct results")
    func singleReaderSerializesConcurrentReads() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 1))
        try await Self.seedCatalog(database, rowCount: 7)

        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    try await Self.countProducts(database)
                }
            }
            var collected: [Int] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        #expect(results.count == 50)
        #expect(results.allSatisfy { $0 == 7 })

        await database.close()
        Self.removeFiles(path)
    }

    @Test("four readers handle thirty-two concurrent reads by waiting and recycling")
    func fourReadersHandleThirtyTwoConcurrentReads() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 4))
        try await Self.seedCatalog(database, rowCount: 12)

        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    try await Self.countProducts(database)
                }
            }
            var collected: [Int] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        #expect(results.count == 32)
        #expect(results.allSatisfy { $0 == 12 })

        await database.close()
        Self.removeFiles(path)
    }

    @Test("one hundred sequential reads reuse the pool and all succeed")
    func sequentialReadsReusePool() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 2))
        try await Self.seedCatalog(database, rowCount: 5)

        var observed: [Int] = []
        for _ in 0..<100 {
            let count = try await Self.countProducts(database)
            observed.append(count)
        }

        #expect(observed.count == 100)
        #expect(observed.allSatisfy { $0 == 5 })

        await database.close()
        Self.removeFiles(path)
    }

    @Test("concurrent reads observe committed state while a write runs")
    func readsObserveCommittedStateDuringWrite() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 4))
        try await Self.seedCatalog(database, rowCount: 10)

        let outcomes = try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                try await database.transaction { writer in
                    for index in 0..<200 {
                        _ = try writer.mutate(
                            "INSERT INTO product(id, sku, price) VALUES (?, ?, ?)",
                            parameters: [.integer(Int64(1000 + index)), .text("EXTRA-\(index)"), .real(0.5)]
                        )
                    }
                    let rows = try writer.query("SELECT COUNT(*) AS total FROM product")
                    return Int(try rows[0].integer(named: "total"))
                }
            }
            for _ in 0..<8 {
                group.addTask {
                    try await Self.countProducts(database)
                }
            }
            var collected: [Int] = []
            for try await outcome in group {
                collected.append(outcome)
            }
            return collected
        }

        #expect(outcomes.count == 9)
        #expect(outcomes.contains(210))
        #expect(outcomes.allSatisfy { $0 == 10 || $0 == 210 })

        let finalCount = try await Self.countProducts(database)
        #expect(finalCount == 210)

        await database.close()
        Self.removeFiles(path)
    }

    @Test("fifty concurrent writes serialize to exactly fifty counter increments")
    func concurrentWritesSerializeWithoutLostUpdates() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 4))
        try await database.write { writer in
            try writer.execute("CREATE TABLE counter (id INTEGER PRIMARY KEY, total INTEGER NOT NULL)")
            _ = try writer.mutate("INSERT INTO counter(id, total) VALUES (1, 0)", parameters: [])
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    try await database.write { writer in
                        _ = try writer.mutate("UPDATE counter SET total = total + 1 WHERE id = 1", parameters: [])
                    }
                }
            }
            for try await _ in group {
            }
        }

        let total = try await database.read { reader in
            let rows = try reader.query("SELECT total FROM counter WHERE id = 1")
            return Int(try rows[0].integer(named: "total"))
        }
        #expect(total == 50)

        await database.close()
        Self.removeFiles(path)
    }

    @Test("a read issued after close throws databaseClosed rather than hanging")
    func readAfterCloseThrows() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 2))
        try await Self.seedCatalog(database, rowCount: 3)

        let before = try await Self.countProducts(database)
        #expect(before == 3)

        await database.close()

        await #expect(throws: SQLiteError.self) {
            _ = try await database.read { reader in
                try reader.query("SELECT COUNT(*) AS total FROM product")
            }
        }

        Self.removeFiles(path)
    }
}
