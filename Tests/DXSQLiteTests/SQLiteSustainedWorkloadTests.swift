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

@Suite("DXSQLite sustained workload")
struct SQLiteSustainedWorkloadTests {

    static let tempPrefix = "dxsqlite-sustained"

    static func makePath() -> String {
        NSTemporaryDirectory() + "\(tempPrefix)-\(UUID().uuidString).sqlite"
    }

    static func removeFiles(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    static func createOrders(_ database: SQLiteDatabase) async throws {
        try await database.write { writer in
            try writer.execute("CREATE TABLE orders (id INTEGER PRIMARY KEY, reference TEXT NOT NULL, amount REAL NOT NULL)")
        }
    }

    static func createCounter(_ database: SQLiteDatabase) async throws {
        try await database.write { writer in
            try writer.execute("CREATE TABLE counter (id INTEGER PRIMARY KEY, total INTEGER NOT NULL)")
            _ = try writer.mutate("INSERT INTO counter (id, total) VALUES (1, 0)", parameters: [])
        }
    }

    static func orderCount(_ database: SQLiteDatabase) async throws -> Int {
        try await database.read { reader in
            let rows = try reader.query("SELECT COUNT(*) AS total FROM orders")
            return Int(try rows[0].integer(named: "total"))
        }
    }

    static func runWriteReadCycle(_ database: SQLiteDatabase, index: Int) async throws -> Bool {
        let reference = "ORDER-\(index)"
        let amount = Double(index) * 2.25
        try await database.write { writer in
            _ = try writer.mutate(
                "INSERT INTO orders (id, reference, amount) VALUES (?, ?, ?)",
                parameters: [.integer(Int64(index)), .text(reference), .real(amount)]
            )
        }
        let readBack = try await database.read { reader -> (String, Double, Int) in
            let rows = try reader.query(
                "SELECT reference, amount FROM orders WHERE id = ?",
                parameters: [.integer(Int64(index))]
            )
            let storedReference = try rows[0].text(named: "reference")
            let storedAmount = try rows[0].double(named: "amount")
            return (storedReference, storedAmount, rows.count)
        }
        return readBack.0 == reference && readBack.1 == amount && readBack.2 == 1
    }

    @Test("several hundred sequential write then read cycles all stay correct")
    func sequentialWriteReadCyclesStayCorrect() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 4))
        try await Self.createOrders(database)

        let cycleCount = 300
        var allMatched = true
        for index in 1...cycleCount {
            let matched = try await Self.runWriteReadCycle(database, index: index)
            allMatched = allMatched && matched
        }

        #expect(allMatched)
        let finalCount = try await Self.orderCount(database)
        #expect(finalCount == cycleCount)

        await database.close()
        Self.removeFiles(path)
    }

    @Test("concurrent reads observe committed data while writes proceed")
    func concurrentReadsObserveCommittedDataDuringWrites() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 4))
        try await Self.createOrders(database)

        let seedCount = 40
        try await database.transaction { writer in
            for index in 1...seedCount {
                _ = try writer.mutate(
                    "INSERT INTO orders (id, reference, amount) VALUES (?, ?, ?)",
                    parameters: [.integer(Int64(index)), .text("SEED-\(index)"), .real(1.0)]
                )
            }
        }

        let readResults = try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                try await database.transaction { writer in
                    for index in 0..<60 {
                        _ = try writer.mutate(
                            "INSERT INTO orders (id, reference, amount) VALUES (?, ?, ?)",
                            parameters: [.integer(Int64(1000 + index)), .text("LIVE-\(index)"), .real(2.0)]
                        )
                    }
                }
                return -1
            }
            for _ in 0..<200 {
                group.addTask {
                    try await Self.orderCount(database)
                }
            }
            var collected: [Int] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        let counts = readResults.filter { $0 >= 0 }
        #expect(counts.count == 200)
        #expect(counts.allSatisfy { $0 == seedCount || $0 == seedCount + 60 })

        let finalCount = try await Self.orderCount(database)
        #expect(finalCount == seedCount + 60)

        await database.close()
        Self.removeFiles(path)
    }

    @Test("three hundred sequential reads reuse a two-connection pool without exhaustion")
    func sequentialReadsReuseBoundedPool() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 2))
        try await Self.createOrders(database)

        let seedCount = 15
        try await database.transaction { writer in
            for index in 1...seedCount {
                _ = try writer.mutate(
                    "INSERT INTO orders (id, reference, amount) VALUES (?, ?, ?)",
                    parameters: [.integer(Int64(index)), .text("FIXED-\(index)"), .real(3.5)]
                )
            }
        }

        var observed: [Int] = []
        for _ in 0..<300 {
            let count = try await Self.orderCount(database)
            observed.append(count)
        }

        #expect(observed.count == 300)
        #expect(observed.allSatisfy { $0 == seedCount })

        await database.close()
        Self.removeFiles(path)
    }

    @Test("a burst of concurrent transactional increments lands exactly the total")
    func concurrentTransactionalIncrementsLandExactTotal() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 4))
        try await Self.createCounter(database)

        let incrementCount = 250
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<incrementCount {
                group.addTask {
                    try await database.transaction { writer in
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
        #expect(total == incrementCount)

        await database.close()
        Self.removeFiles(path)
    }
}
