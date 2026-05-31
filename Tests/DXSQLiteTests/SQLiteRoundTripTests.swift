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

@Suite("DXSQLite writer and reader round trip")
struct SQLiteRoundTripTests {

    @Test("a write commits and a pooled reader sees it")
    func writeThenRead() async throws {
        let path = NSTemporaryDirectory() + "dxsqlite-\(UUID().uuidString).sqlite"
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 3))

        let changed = try await database.write { writer -> Int in
            try writer.execute("CREATE TABLE item (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
            return try writer.mutate("INSERT INTO item(name) VALUES (?)", parameters: [.text("Ada")])
        }
        #expect(changed == 1)

        let rows = try await database.read { reader in
            try reader.query("SELECT id, name FROM item ORDER BY id")
        }
        #expect(rows.count == 1)
        let first = try #require(rows.first)
        #expect(try first.value(named: "id") == .integer(1))
        #expect(try first.value(named: "name") == .text("Ada"))

        await database.close()
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    @Test("concurrent reads run against the pool")
    func concurrentReads() async throws {
        let path = NSTemporaryDirectory() + "dxsqlite-\(UUID().uuidString).sqlite"
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 8))
        try await database.write { writer in
            try writer.execute("CREATE TABLE n (v INTEGER NOT NULL)")
            for value in 1...50 {
                _ = try writer.mutate("INSERT INTO n(v) VALUES (?)", parameters: [.integer(Int64(value))])
            }
        }

        let totals = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let rows = try await database.read { reader in
                        try reader.query("SELECT COUNT(*) AS c FROM n")
                    }
                    let value = try rows[0].value(named: "c")
                    guard case .integer(let count) = value else { return -1 }
                    return Int(count)
                }
            }
            var collected: [Int] = []
            for try await total in group {
                collected.append(total)
            }
            return collected
        }

        #expect(totals.count == 8)
        #expect(totals.allSatisfy { $0 == 50 })

        await database.close()
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }
}
