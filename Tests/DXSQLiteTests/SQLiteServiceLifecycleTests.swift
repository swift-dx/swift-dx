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
import Logging
import ServiceLifecycle
import Testing
import DXSQLite

@Suite("DXSQLite ServiceLifecycle integration")
struct SQLiteServiceLifecycleTests {

    @Test("run parks until graceful shutdown, then closes the database")
    func runClosesOnGracefulShutdown() async throws {
        let path = NSTemporaryDirectory() + "dxsqlite-service-\(UUID().uuidString).sqlite"
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await database.write { writer in
            try writer.execute("CREATE TABLE t (v INTEGER)")
        }

        let group = ServiceGroup(services: [database], logger: Logger(label: "swift.dx.sqlite.test"))
        let runTask = Task { try await group.run() }
        try await Task.sleep(for: .milliseconds(150))
        await group.triggerGracefulShutdown()
        try await runTask.value

        await #expect(throws: SQLiteError.self) {
            _ = try await database.read { reader in
                try reader.query("SELECT count(*) AS n FROM t")
            }
        }

        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }
}
