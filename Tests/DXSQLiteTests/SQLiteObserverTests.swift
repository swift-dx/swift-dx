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
import Synchronization
import Testing
import DXSQLite

@Suite("DXSQLite observers")
struct SQLiteObserverTests {

    final class TraceRecorder: Sendable {

        private let statements = Mutex<[String]>([])

        func record(_ statement: String) {
            statements.withLock { $0.append(statement) }
        }

        func snapshot() -> [String] {
            statements.withLock { $0 }
        }
    }

    @Test("the trace observer reports executed statements")
    func trace() async throws {
        let path = NSTemporaryDirectory() + "dxsqlite-trace-\(UUID().uuidString).sqlite"
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        let recorder = TraceRecorder()
        try await database.observeTrace { statement in recorder.record(statement) }

        try await database.write { writer in
            try writer.execute("CREATE TABLE t (v INTEGER)")
            _ = try writer.mutate("INSERT INTO t(v) VALUES (1)", parameters: [])
        }

        let traced = recorder.snapshot()
        #expect(traced.contains { $0.contains("CREATE TABLE") })
        #expect(traced.contains { $0.contains("INSERT INTO t") })

        await database.close()
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }
}
