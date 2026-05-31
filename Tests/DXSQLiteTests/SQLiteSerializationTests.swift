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

@Suite("DXSQLite serialization")
struct SQLiteSerializationTests {

    @Test("serialize produces a valid standalone database image")
    func serialize() async throws {
        let sourcePath = NSTemporaryDirectory() + "dxsqlite-ser-\(UUID().uuidString).sqlite"
        let imagePath = NSTemporaryDirectory() + "dxsqlite-img-\(UUID().uuidString).sqlite"

        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: sourcePath)))
        let snapshot = try await database.write { writer -> [UInt8] in
            try writer.execute("CREATE TABLE t (v INTEGER NOT NULL)")
            _ = try writer.mutate("INSERT INTO t(v) VALUES (7)", parameters: [])
            return try writer.serialize()
        }
        await database.close()
        #expect(snapshot.count > 0)

        try Data(snapshot).write(to: URL(fileURLWithPath: imagePath))
        let restored = try await SQLite.connect(SQLiteConfiguration(location: .file(path: imagePath)))
        let rows = try await restored.read { reader in
            try reader.query("SELECT v FROM t")
        }
        #expect(try #require(rows.first).integer(named: "v") == 7)
        await restored.close()

        for candidate in [sourcePath, imagePath] {
            try? FileManager.default.removeItem(atPath: candidate)
            try? FileManager.default.removeItem(atPath: candidate + "-wal")
            try? FileManager.default.removeItem(atPath: candidate + "-shm")
        }
    }
}
