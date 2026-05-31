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

@Suite("DXSQLite reader pool cancellation")
struct SQLiteReaderPoolCancellationTests {

    static func makePath() -> String {
        NSTemporaryDirectory() + "dxsqlite-cancel-\(UUID().uuidString).sqlite"
    }

    static func removeFiles(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    @Test("a read cancelled while waiting for a saturated pool throws rather than hanging")
    func cancelledWaiterThrows() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 1))
        try await database.write { writer in
            try writer.execute("CREATE TABLE t (v INTEGER)")
        }

        let holder = Task {
            try await database.read { _ -> Int in
                Thread.sleep(forTimeInterval: 0.7)
                return 0
            }
        }
        try await Task.sleep(for: .milliseconds(150))

        let waiter = Task {
            try await database.read { reader in
                try reader.query("SELECT count(*) AS n FROM t")[0].integer(named: "n")
            }
        }
        try await Task.sleep(for: .milliseconds(80))
        waiter.cancel()

        var outcome = "succeeded"
        do {
            _ = try await waiter.value
        } catch is CancellationError {
            outcome = "cancelled"
        } catch {
            outcome = "othererror"
        }
        #expect(outcome == "cancelled")

        _ = try? await holder.value
        await database.close()
        Self.removeFiles(path)
    }

    @Test("an uncancelled waiter still receives the connection once it frees up")
    func uncancelledWaiterStillSucceeds() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 1))
        try await database.write { writer in
            try writer.execute("CREATE TABLE t (v INTEGER)")
            _ = try writer.mutate("INSERT INTO t (v) VALUES (42)", parameters: [])
        }

        let holder = Task {
            try await database.read { _ -> Int in
                Thread.sleep(forTimeInterval: 0.3)
                return 0
            }
        }
        try await Task.sleep(for: .milliseconds(120))

        let value = try await database.read { reader in
            try reader.query("SELECT v FROM t")[0].integer(named: "v")
        }
        #expect(value == 42)

        _ = try? await holder.value
        await database.close()
        Self.removeFiles(path)
    }
}
