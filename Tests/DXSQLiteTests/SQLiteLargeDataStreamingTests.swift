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

@Suite("DXSQLite large-data streaming")
struct SQLiteLargeDataStreamingTests {

    static let tempPrefix = "dxsqlite-largestream"

    static let datasetRowCount = 5_000

    static func makePath() -> String {
        NSTemporaryDirectory() + "\(tempPrefix)-\(UUID().uuidString).sqlite"
    }

    static func removeFiles(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    static func seedDataset(_ database: SQLiteDatabase, rowCount: Int) async throws {
        try await database.transaction { writer in
            try writer.execute("CREATE TABLE event (id INTEGER PRIMARY KEY, label TEXT NOT NULL, amount REAL NOT NULL, even INTEGER NOT NULL)")
            for index in 0..<rowCount {
                let id = Int64(index + 1)
                _ = try writer.mutate(
                    "INSERT INTO event(id, label, amount, even) VALUES (?, ?, ?, ?)",
                    parameters: [.integer(id), .text("EVENT-\(id)"), .real(Double(index) * 0.25), .integer(id % 2 == 0 ? 1 : 0)]
                )
            }
        }
    }

    @Test("streaming the full table delivers every row in ascending id order")
    func streamFullTableInOrder() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 4))
        try await Self.seedDataset(database, rowCount: Self.datasetRowCount)

        var observedCount = 0
        var previousID: Int64 = 0
        var ascending = true
        for try await row in database.readStream("SELECT id, label FROM event ORDER BY id") {
            let id = try row.integer(named: "id")
            if id <= previousID {
                ascending = false
            }
            previousID = id
            observedCount += 1
        }

        #expect(observedCount == Self.datasetRowCount)
        #expect(ascending)
        #expect(previousID == Int64(Self.datasetRowCount))

        await database.close()
        Self.removeFiles(path)
    }

    @Test("breaking out of the stream early stops cleanly without hanging")
    func streamEarlyTermination() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 4))
        try await Self.seedDataset(database, rowCount: Self.datasetRowCount)

        let stopAfter = 100
        var consumed: [Int64] = []
        for try await row in database.readStream("SELECT id FROM event ORDER BY id") {
            consumed.append(try row.integer(named: "id"))
            if consumed.count == stopAfter {
                break
            }
        }

        #expect(consumed.count == stopAfter)
        #expect(consumed.first == 1)
        #expect(consumed.last == Int64(stopAfter))

        let postCount = try await database.read { reader in
            let rows = try reader.query("SELECT COUNT(*) AS total FROM event")
            return Int(try rows[0].integer(named: "total"))
        }
        #expect(postCount == Self.datasetRowCount)

        await database.close()
        Self.removeFiles(path)
    }

    @Test("streaming a slice matches the materializing query for the same slice")
    func streamMatchesMaterializedQuery() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 4))
        try await Self.seedDataset(database, rowCount: Self.datasetRowCount)

        let sliceSize = 250
        let sql = "SELECT id, label, amount FROM event ORDER BY id LIMIT \(sliceSize)"

        var streamed: [SQLiteRow] = []
        for try await row in database.readStream(sql) {
            streamed.append(row)
        }

        let materialized = try await database.read { reader in
            try reader.query(sql)
        }

        #expect(streamed.count == sliceSize)
        #expect(materialized.count == sliceSize)
        #expect(streamed == materialized)

        await database.close()
        Self.removeFiles(path)
    }

    @Test("a filtered stream yields only the rows matching the predicate")
    func streamWithWhereFilter() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 4))
        try await Self.seedDataset(database, rowCount: Self.datasetRowCount)

        var matchedIds: [Int64] = []
        for try await row in database.readStream("SELECT id, even FROM event WHERE even = ? ORDER BY id", parameters: [.integer(1)]) {
            matchedIds.append(try row.integer(named: "id"))
        }

        #expect(matchedIds.count == Self.datasetRowCount / 2)
        #expect(matchedIds.allSatisfy { $0 % 2 == 0 })

        await database.close()
        Self.removeFiles(path)
    }
}
