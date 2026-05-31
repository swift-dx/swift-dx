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

@Suite("DXSQLite WAL snapshot isolation")
struct SQLiteSnapshotIsolationTests {

    static let tempPrefix = "dxsqlite-snapshot"

    static func makePath() -> String {
        NSTemporaryDirectory() + "\(tempPrefix)-\(UUID().uuidString).sqlite"
    }

    static func removeFiles(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    static func seedOrders(_ database: SQLiteDatabase, rowCount: Int) async throws {
        try await database.write { writer in
            try writer.execute("CREATE TABLE orders (id INTEGER PRIMARY KEY, reference TEXT NOT NULL, amount REAL NOT NULL)")
            for index in 0..<rowCount {
                _ = try writer.mutate(
                    "INSERT INTO orders(id, reference, amount) VALUES (?, ?, ?)",
                    parameters: [.integer(Int64(index + 1)), .text("REF-\(index + 1)"), .real(Double(index + 1) * 2.0)]
                )
            }
        }
    }

    static func countOrders(_ database: SQLiteDatabase) async throws -> Int {
        try await database.read { reader in
            let rows = try reader.query("SELECT COUNT(*) AS total FROM orders")
            let total = try rows[0].integer(named: "total")
            return Int(total)
        }
    }

    @Test("readers see the prior committed snapshot while a write transaction is held open")
    func readersSeePriorSnapshotWhileTransactionHeld() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 4))
        let beforeCount = 10
        let insertCount = 40
        try await Self.seedOrders(database, rowCount: beforeCount)

        let duringReads = try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                try await database.transaction { writer in
                    for index in 0..<insertCount {
                        _ = try writer.mutate(
                            "INSERT INTO orders(id, reference, amount) VALUES (?, ?, ?)",
                            parameters: [.integer(Int64(1000 + index)), .text("HOLD-\(index)"), .real(1.0)]
                        )
                    }
                    Thread.sleep(forTimeInterval: 0.30)
                    return -1
                }
            }
            for _ in 0..<6 {
                group.addTask {
                    try await Task.sleep(nanoseconds: 60_000_000)
                    return try await Self.countOrders(database)
                }
            }
            var collected: [Int] = []
            for try await result in group {
                if result >= 0 {
                    collected.append(result)
                }
            }
            return collected
        }

        #expect(duringReads.count == 6)
        #expect(duringReads.allSatisfy { $0 == beforeCount })

        let afterCommit = try await Self.countOrders(database)
        #expect(afterCommit == beforeCount + insertCount)

        await database.close()
        Self.removeFiles(path)
    }

    @Test("a reader started after commit sees exactly prior plus inserted rows")
    func readerAfterCommitSeesExactSum() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 2))
        let beforeCount = 25
        let insertCount = 50
        try await Self.seedOrders(database, rowCount: beforeCount)

        let observedBefore = try await Self.countOrders(database)
        #expect(observedBefore == beforeCount)

        try await database.transaction { writer in
            for index in 0..<insertCount {
                _ = try writer.mutate(
                    "INSERT INTO orders(id, reference, amount) VALUES (?, ?, ?)",
                    parameters: [.integer(Int64(2000 + index)), .text("ADD-\(index)"), .real(3.0)]
                )
            }
        }

        let observedAfter = try await Self.countOrders(database)
        #expect(observedAfter == beforeCount + insertCount)
        #expect(observedAfter == observedBefore + insertCount)

        await database.close()
        Self.removeFiles(path)
    }

    @Test("concurrent samples never observe a partially applied transaction")
    func samplesNeverObservePartialTransaction() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 4))
        let beforeCount = 30
        let insertCount = 60
        let afterCount = beforeCount + insertCount
        try await Self.seedOrders(database, rowCount: beforeCount)

        let samples = try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                try await database.transaction { writer in
                    for index in 0..<insertCount {
                        _ = try writer.mutate(
                            "INSERT INTO orders(id, reference, amount) VALUES (?, ?, ?)",
                            parameters: [.integer(Int64(3000 + index)), .text("ATOMIC-\(index)"), .real(4.0)]
                        )
                    }
                    Thread.sleep(forTimeInterval: 0.10)
                    return -1
                }
            }
            for sample in 0..<24 {
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(sample) * 8_000_000)
                    return try await Self.countOrders(database)
                }
            }
            var collected: [Int] = []
            for try await result in group {
                if result >= 0 {
                    collected.append(result)
                }
            }
            return collected
        }

        let allowed: Set<Int> = [beforeCount, afterCount]
        #expect(samples.count == 24)
        #expect(samples.allSatisfy { allowed.contains($0) })

        let finalCount = try await Self.countOrders(database)
        #expect(finalCount == afterCount)

        await database.close()
        Self.removeFiles(path)
    }
}
