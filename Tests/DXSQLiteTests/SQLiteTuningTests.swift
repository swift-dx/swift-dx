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

@Suite("DXSQLite storage tuning")
struct SQLiteTuningTests {

    static func temporaryPath() -> String {
        NSTemporaryDirectory() + "dxsqlite-tuning-\(UUID().uuidString).sqlite"
    }

    static func removeDatabase(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    @Test("the default tuning reproduces SQLite's standard settings")
    func defaultTuningPragmas() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            let synchronous = try writer.query("PRAGMA synchronous")[0].integer(named: "synchronous")
            let pageSize = try writer.query("PRAGMA page_size")[0].integer(named: "page_size")
            let cacheSize = try writer.query("PRAGMA cache_size")[0].integer(named: "cache_size")
            let mmapSize = try writer.query("PRAGMA mmap_size")[0].integer(named: "mmap_size")
            #expect(synchronous == 1)
            #expect(pageSize == 4096)
            #expect(cacheSize == -2000)
            #expect(mmapSize == 0)
        }

        await database.close()
        Self.removeDatabase(at: path)
    }

    @Test("a custom tuning is applied to the writer connection")
    func customTuningOnWriter() async throws {
        let path = Self.temporaryPath()
        let tuning = SQLiteTuning(synchronous: .full, cacheSizeKibibytes: 8192, mmapSizeBytes: 67_108_864, pageSize: 8192)
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), tuning: tuning))

        try await database.write { writer in
            let synchronous = try writer.query("PRAGMA synchronous")[0].integer(named: "synchronous")
            let pageSize = try writer.query("PRAGMA page_size")[0].integer(named: "page_size")
            let cacheSize = try writer.query("PRAGMA cache_size")[0].integer(named: "cache_size")
            let mmapSize = try writer.query("PRAGMA mmap_size")[0].integer(named: "mmap_size")
            #expect(synchronous == 2)
            #expect(pageSize == 8192)
            #expect(cacheSize == -8192)
            #expect(mmapSize == 67_108_864)
        }

        await database.close()
        Self.removeDatabase(at: path)
    }

    @Test("a custom cache size is applied to pooled reader connections too")
    func customTuningOnReader() async throws {
        let path = Self.temporaryPath()
        let tuning = SQLiteTuning(cacheSizeKibibytes: 4096)
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 2, tuning: tuning))

        try await database.write { writer in
            try writer.execute("CREATE TABLE t (v INTEGER)")
        }
        let cacheSize = try await database.read { reader in
            try reader.query("PRAGMA cache_size")[0].integer(named: "cache_size")
        }
        #expect(cacheSize == -4096)

        await database.close()
        Self.removeDatabase(at: path)
    }

    @Test("the full synchronous mode keeps writes durable and readable")
    func fullSynchronousRoundTrips() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), tuning: SQLiteTuning(synchronous: .full)))

        try await database.transaction { writer in
            try writer.execute("CREATE TABLE ledger (id INTEGER PRIMARY KEY, amount INTEGER NOT NULL)")
            _ = try writer.mutate("INSERT INTO ledger (id, amount) VALUES (1, 500)", parameters: [])
        }
        let amount = try await database.read { reader in
            try reader.query("SELECT amount FROM ledger WHERE id = 1")[0].integer(named: "amount")
        }
        #expect(amount == 500)

        await database.close()
        Self.removeDatabase(at: path)
    }
}
