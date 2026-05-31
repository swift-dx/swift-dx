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

@Suite("DXSQLite production tuning flow")
struct SQLiteProductionTuningFlowTests {

    static let tempPrefix = "dxsqlite-prodtune"

    static let orderCount = 300

    static func makePath() -> String {
        NSTemporaryDirectory() + "\(tempPrefix)-\(UUID().uuidString).sqlite"
    }

    static func removeFiles(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    static func productionTuning(synchronous: SQLiteSynchronousMode) -> SQLiteTuning {
        SQLiteTuning(synchronous: synchronous, cacheSizeKibibytes: 16384, mmapSizeBytes: 67_108_864, pageSize: 8192)
    }

    static func seedOrders(_ database: SQLiteDatabase, count: Int) async throws {
        try await database.transaction { writer in
            try writer.execute("CREATE TABLE orders (id INTEGER PRIMARY KEY, reference TEXT NOT NULL, total REAL NOT NULL, fulfilled INTEGER NOT NULL)")
            for index in 0..<count {
                let identifier = index + 1
                _ = try writer.mutate(
                    "INSERT INTO orders(id, reference, total, fulfilled) VALUES (?, ?, ?, ?)",
                    parameters: [.integer(Int64(identifier)), .text("ORD-\(identifier)"), .real(Double(identifier) * 2.25), .integer(index % 2 == 0 ? 1 : 0)]
                )
            }
        }
    }

    static func orderTotal(_ database: SQLiteDatabase, id: Int) async throws -> Double {
        try await database.read { reader in
            let rows = try reader.query("SELECT total FROM orders WHERE id = ?", parameters: [.integer(Int64(id))])
            let total = try rows[0].double(named: "total")
            return total
        }
    }

    static func countOrders(_ database: SQLiteDatabase) async throws -> Int {
        try await database.read { reader in
            let rows = try reader.query("SELECT COUNT(*) AS total FROM orders")
            let count = try rows[0].integer(named: "total")
            return Int(count)
        }
    }

    @Test("a production-tuned database serves a seeded workload under concurrent point reads")
    func tunedWorkloadServesConcurrentPointReads() async throws {
        let path = Self.makePath()
        let configuration = SQLiteConfiguration(
            location: .file(path: path),
            maxReaders: 8,
            tuning: Self.productionTuning(synchronous: .full)
        )
        let database = try await SQLite.connect(configuration)
        try await Self.seedOrders(database, count: Self.orderCount)

        let total = try await Self.countOrders(database)
        #expect(total == Self.orderCount)

        let results = try await withThrowingTaskGroup(of: Double.self) { group in
            for id in 1...Self.orderCount {
                group.addTask {
                    try await Self.orderTotal(database, id: id)
                }
            }
            var collected: [Double] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        #expect(results.count == Self.orderCount)
        let expectedSum = (1...Self.orderCount).reduce(0.0) { $0 + Double($1) * 2.25 }
        let observedSum = results.reduce(0.0, +)
        #expect(abs(observedSum - expectedSum) < 0.001)

        await database.close()
        Self.removeFiles(path)
    }

    @Test("the configured tuning pragmas are applied to the writer connection")
    func tuningPragmasAppliedToWriter() async throws {
        let path = Self.makePath()
        let configuration = SQLiteConfiguration(
            location: .file(path: path),
            maxReaders: 8,
            tuning: Self.productionTuning(synchronous: .full)
        )
        let database = try await SQLite.connect(configuration)

        try await database.write { writer in
            let synchronous = try writer.query("PRAGMA synchronous")[0].integer(named: "synchronous")
            let pageSize = try writer.query("PRAGMA page_size")[0].integer(named: "page_size")
            let cacheSize = try writer.query("PRAGMA cache_size")[0].integer(named: "cache_size")
            #expect(synchronous == 2)
            #expect(pageSize == 8192)
            #expect(cacheSize == -16384)
        }

        await database.close()
        Self.removeFiles(path)
    }

    @Test("the same workload remains correct under the normal durability mode")
    func normalDurabilityWorkloadRemainsCorrect() async throws {
        let path = Self.makePath()
        let configuration = SQLiteConfiguration(
            location: .file(path: path),
            maxReaders: 8,
            tuning: Self.productionTuning(synchronous: .normal)
        )
        let database = try await SQLite.connect(configuration)

        try await database.write { writer in
            let synchronous = try writer.query("PRAGMA synchronous")[0].integer(named: "synchronous")
            #expect(synchronous == 1)
        }

        try await Self.seedOrders(database, count: Self.orderCount)

        let total = try await Self.countOrders(database)
        #expect(total == Self.orderCount)

        let sampled = try await withThrowingTaskGroup(of: Double.self) { group in
            for id in stride(from: 1, through: Self.orderCount, by: 3) {
                group.addTask {
                    try await Self.orderTotal(database, id: id)
                }
            }
            var collected: [Double] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        #expect(sampled.allSatisfy { $0 > 0 })
        let lastTotal = try await Self.orderTotal(database, id: Self.orderCount)
        #expect(abs(lastTotal - Double(Self.orderCount) * 2.25) < 0.001)

        await database.close()
        Self.removeFiles(path)
    }

    @Test("a read-mostly mix over a tuned database completes with correct results")
    func readMostlyMixCompletesCorrectly() async throws {
        let path = Self.makePath()
        let configuration = SQLiteConfiguration(
            location: .file(path: path),
            maxReaders: 8,
            tuning: Self.productionTuning(synchronous: .normal)
        )
        let database = try await SQLite.connect(configuration)
        try await Self.seedOrders(database, count: Self.orderCount)

        let readOutcomes = try await withThrowingTaskGroup(of: Int.self) { group in
            for batch in 0..<5 {
                group.addTask {
                    try await database.write { writer in
                        let identifier = Self.orderCount + batch + 1
                        _ = try writer.mutate(
                            "INSERT INTO orders(id, reference, total, fulfilled) VALUES (?, ?, ?, ?)",
                            parameters: [.integer(Int64(identifier)), .text("ORD-EXTRA-\(identifier)"), .real(Double(identifier) * 2.25), true]
                        )
                    }
                    return try await Self.countOrders(database)
                }
            }
            for _ in 0..<150 {
                group.addTask {
                    try await Self.countOrders(database)
                }
            }
            var collected: [Int] = []
            for try await outcome in group {
                collected.append(outcome)
            }
            return collected
        }

        #expect(readOutcomes.count == 155)
        #expect(readOutcomes.allSatisfy { $0 >= Self.orderCount && $0 <= Self.orderCount + 5 })

        let finalCount = try await Self.countOrders(database)
        #expect(finalCount == Self.orderCount + 5)

        await database.close()
        Self.removeFiles(path)
    }
}
