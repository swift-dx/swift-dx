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

@Suite("DXSQLite blob bounds")
struct SQLiteBlobBoundsTests {

    static func makePath() -> String {
        NSTemporaryDirectory() + "dxsqlite-blobbounds-\(UUID().uuidString).sqlite"
    }

    static func removeFiles(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    static func seedCell(_ database: SQLiteDatabase) async throws {
        try await database.write { writer in
            try writer.execute("CREATE TABLE cell (id INTEGER PRIMARY KEY, payload BLOB NOT NULL)")
            _ = try writer.mutate("INSERT INTO cell (id, payload) VALUES (1, zeroblob(16))", parameters: [])
        }
    }

    @Test("a read count beyond 32-bit range throws instead of trapping")
    func oversizedReadCountThrows() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await Self.seedCell(database)

        await #expect(throws: SQLiteError.self) {
            try await database.write { writer in
                try writer.withBlob(table: "cell", column: "payload", rowID: 1) { blob in
                    _ = try blob.read(count: Int(Int32.max) + 1, at: 0)
                }
            }
        }

        await database.close()
        Self.removeFiles(path)
    }

    @Test("a negative read count throws instead of trapping")
    func negativeReadCountThrows() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await Self.seedCell(database)

        await #expect(throws: SQLiteError.self) {
            try await database.write { writer in
                try writer.withBlob(table: "cell", column: "payload", rowID: 1) { blob in
                    _ = try blob.read(count: -1, at: 0)
                }
            }
        }

        await database.close()
        Self.removeFiles(path)
    }

    @Test("a write offset beyond 32-bit range throws instead of trapping")
    func oversizedWriteOffsetThrows() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await Self.seedCell(database)

        await #expect(throws: SQLiteError.self) {
            try await database.write { writer in
                try writer.withBlob(table: "cell", column: "payload", rowID: 1) { blob in
                    try blob.write([1, 2, 3], at: Int(Int32.max) + 5)
                }
            }
        }

        await database.close()
        Self.removeFiles(path)
    }

    @Test("an in-range incremental read and write still round-trip")
    func inRangeBlobStillWorks() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await Self.seedCell(database)

        try await database.write { writer in
            try writer.withBlob(table: "cell", column: "payload", rowID: 1) { blob in
                try blob.write([10, 20, 30, 40], at: 0)
            }
        }
        let head = try await database.read { reader in
            try reader.withBlob(table: "cell", column: "payload", rowID: 1) { blob in
                try blob.read(count: 4, at: 0)
            }
        }
        #expect(head == [10, 20, 30, 40])

        await database.close()
        Self.removeFiles(path)
    }
}
