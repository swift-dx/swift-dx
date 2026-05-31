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

@Suite("DXSQLite ambient request pattern")
struct SQLiteAmbientRequestPatternTests {

    static let tempPrefix = "dxsqlite-ambient"

    static func makePath() -> String {
        NSTemporaryDirectory() + "\(tempPrefix)-\(UUID().uuidString).sqlite"
    }

    static func removeFiles(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    static func createOrderTable() async throws {
        let database = try SQLite.current()
        try await database.write { writer in
            try writer.execute("CREATE TABLE IF NOT EXISTS purchase_order (id INTEGER PRIMARY KEY, customer TEXT NOT NULL, total REAL NOT NULL)")
        }
    }

    static func placeOrder(customer: String, total: Double) async throws -> Int64 {
        let database = try SQLite.current()
        return try await database.write { writer in
            _ = try writer.mutate(
                "INSERT INTO purchase_order(customer, total) VALUES (?, ?)",
                parameters: [.text(customer), .real(total)]
            )
            return writer.lastInsertRowID
        }
    }

    static func handleRequest(customer: String, total: Double) async throws -> Int64 {
        try await Self.createOrderTable()
        return try await Self.placeOrder(customer: customer, total: total)
    }

    static func countOrders() async throws -> Int {
        let database = try SQLite.current()
        return try await database.read { reader in
            let rows = try reader.query("SELECT COUNT(*) AS total FROM purchase_order")
            let count = try rows[0].integer(named: "total")
            return Int(count)
        }
    }

    @Test("a deeply nested request helper resolves the ambient database and persists work")
    func nestedHelperResolvesAmbientDatabase() async throws {
        let path = Self.makePath()
        let identifier = try await SQLite.withDatabase(SQLiteConfiguration(location: .file(path: path))) { database in
            try await SQLite.withCurrent(database) {
                let newID = try await Self.handleRequest(customer: "Customer-A", total: 42.5)
                let resolved = try SQLite.current()
                let total = try await resolved.read { reader in
                    let rows = try reader.query("SELECT total FROM purchase_order WHERE id = ?", parameters: [.integer(newID)])
                    let value = try rows[0].double(named: "total")
                    return value
                }
                #expect(total == 42.5)
                return newID
            }
        }

        #expect(identifier == 1)
        Self.removeFiles(path)
    }

    @Test("sequential requests each bind the ambient database and accumulate shared state")
    func sequentialRequestsAccumulateState() async throws {
        let path = Self.makePath()
        let finalCount = try await SQLite.withDatabase(SQLiteConfiguration(location: .file(path: path))) { database in
            for index in 0..<25 {
                try await SQLite.withCurrent(database) {
                    _ = try await Self.handleRequest(customer: "Customer-\(index)", total: Double(index) + 0.25)
                }
            }
            return try await SQLite.withCurrent(database) {
                try await Self.countOrders()
            }
        }

        #expect(finalCount == 25)
        Self.removeFiles(path)
    }

    @Test("concurrent requests each receive the ambient binding and all succeed")
    func concurrentRequestsResolveAmbientBinding() async throws {
        let path = Self.makePath()
        let totalInserted = try await SQLite.withDatabase(SQLiteConfiguration(location: .file(path: path), maxReaders: 4)) { database in
            try await SQLite.withCurrent(database) {
                try await Self.createOrderTable()
            }

            let identifiers = try await withThrowingTaskGroup(of: Int64.self) { group in
                for index in 0..<60 {
                    group.addTask {
                        try await SQLite.withCurrent(database) {
                            let resolved = try SQLite.current()
                            #expect(resolved === database)
                            return try await Self.placeOrder(customer: "Customer-\(index)", total: Double(index))
                        }
                    }
                }
                var collected: [Int64] = []
                for try await identifier in group {
                    collected.append(identifier)
                }
                return collected
            }

            #expect(identifiers.count == 60)
            #expect(Set(identifiers).count == 60)

            return try await SQLite.withCurrent(database) {
                try await Self.countOrders()
            }
        }

        #expect(totalInserted == 60)
        Self.removeFiles(path)
    }

    @Test("current outside any withCurrent scope throws noCurrentDatabase")
    func currentOutsideScopeThrows() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        #expect(throws: SQLiteError.noCurrentDatabase) {
            _ = try SQLite.current()
        }

        try await SQLite.withCurrent(database) {
            let resolved = try SQLite.current()
            #expect(resolved === database)
        }

        #expect(throws: SQLiteError.noCurrentDatabase) {
            _ = try SQLite.current()
        }

        await database.close()
        Self.removeFiles(path)
    }

    @Test("withDatabase closes the database so a later read on the captured reference throws")
    func withDatabaseClosesAfterBody() async throws {
        let path = Self.makePath()
        let captured = try await SQLite.withDatabase(SQLiteConfiguration(location: .file(path: path))) { database in
            try await SQLite.withCurrent(database) {
                try await Self.createOrderTable()
                _ = try await Self.placeOrder(customer: "Customer-Z", total: 9.0)
            }
            return database
        }

        await #expect(throws: SQLiteError.self) {
            _ = try await captured.read { reader in
                try reader.query("SELECT COUNT(*) AS total FROM purchase_order")
            }
        }

        Self.removeFiles(path)
    }
}
