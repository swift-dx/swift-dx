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
import ServiceLifecycle
import Logging

@Suite("DXSQLite service workload")
struct SQLiteServiceWorkloadTests {

    static let tempPrefix = "dxsqlite-svcwork"

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
            try writer.execute("CREATE TABLE \"order\" (id INTEGER PRIMARY KEY, reference TEXT NOT NULL, amount REAL NOT NULL)")
        }
    }

    static func insertOrders(_ database: SQLiteDatabase, startingAt start: Int, count: Int) async throws {
        try await database.transaction { writer in
            for offset in 0..<count {
                let identifier = start + offset
                _ = try writer.mutate(
                    "INSERT INTO \"order\"(id, reference, amount) VALUES (?, ?, ?)",
                    parameters: [.integer(Int64(identifier)), .text("REF-\(identifier)"), .real(Double(identifier) * 2.0)]
                )
            }
        }
    }

    static func countOrders(_ database: SQLiteDatabase) async throws -> Int {
        try await database.read { reader in
            let rows = try reader.query("SELECT COUNT(*) AS total FROM \"order\"")
            let total = try rows[0].integer(named: "total")
            return Int(total)
        }
    }

    @Test("workload runs against the service group then a post-shutdown read fails")
    func workloadUnderRunningServiceGroup() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 4))
        try await Self.createOrders(database)

        let logger = Logger(label: "test")
        let group = ServiceGroup(services: [database], logger: logger)

        let runTask = Task {
            try await group.run()
        }

        try await Task.sleep(for: .milliseconds(50))

        try await Self.insertOrders(database, startingAt: 1, count: 300)
        let writtenCount = try await Self.countOrders(database)
        #expect(writtenCount == 300)

        let concurrentCounts = try await withThrowingTaskGroup(of: Int.self) { tasks in
            for _ in 0..<16 {
                tasks.addTask {
                    try await Self.countOrders(database)
                }
            }
            var collected: [Int] = []
            for try await value in tasks {
                collected.append(value)
            }
            return collected
        }
        #expect(concurrentCounts.count == 16)
        #expect(concurrentCounts.allSatisfy { $0 == 300 })

        await group.triggerGracefulShutdown()
        try await runTask.value

        await #expect(throws: SQLiteError.self) {
            _ = try await database.read { reader in
                try reader.query("SELECT COUNT(*) AS total FROM \"order\"")
            }
        }

        Self.removeFiles(path)
    }

    @Test("rows committed before graceful shutdown are durable on reopen")
    func committedWorkIsDurableAfterShutdown() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 2, tuning: SQLiteTuning(synchronous: .full)))
        try await Self.createOrders(database)

        let logger = Logger(label: "test")
        let group = ServiceGroup(services: [database], logger: logger)

        let runTask = Task {
            try await group.run()
        }

        try await Task.sleep(for: .milliseconds(50))

        try await Self.insertOrders(database, startingAt: 1000, count: 250)
        let observedBeforeShutdown = try await Self.countOrders(database)
        #expect(observedBeforeShutdown == 250)

        await group.triggerGracefulShutdown()
        try await runTask.value

        let reopened = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 2))
        let durableCount = try await Self.countOrders(reopened)
        #expect(durableCount == 250)

        let referencePresent = try await reopened.read { reader in
            let rows = try reader.query("SELECT reference FROM \"order\" WHERE id = ?", parameters: [.integer(1042)])
            let reference = try rows[0].text(named: "reference")
            return reference
        }
        #expect(referencePresent == "REF-1042")

        await reopened.close()
        Self.removeFiles(path)
    }
}
