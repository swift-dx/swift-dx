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

@Suite("DXSQLite typed value accessors")
struct SQLiteValueAccessorTests {

    @Test("typed accessors return the underlying column value")
    func typedReads() async throws {
        let path = NSTemporaryDirectory() + "dxsqlite-\(UUID().uuidString).sqlite"
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await database.write { writer in
            try writer.execute("CREATE TABLE m (i INTEGER, r REAL, t TEXT, b BLOB, flag INTEGER)")
            _ = try writer.mutate(
                "INSERT INTO m (i, r, t, b, flag) VALUES (?, ?, ?, ?, ?)",
                parameters: [.integer(7), .real(2.5), .text("hi"), .blob([1, 2, 3]), .integer(1)]
            )
        }

        let rows = try await database.read { reader in
            try reader.query("SELECT i, r, t, b, flag FROM m")
        }
        let row = try #require(rows.first)
        #expect(try row.integer(named: "i") == 7)
        #expect(try row.double(named: "r") == 2.5)
        #expect(try row.text(named: "t") == "hi")
        #expect(try row.blob(named: "b") == [1, 2, 3])
        #expect(try row.boolean(named: "flag") == true)

        await database.close()
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    @Test("reading a value as the wrong type throws valueTypeMismatch")
    func mismatchThrows() {
        let value = SQLiteValue.text("not a number")
        #expect(throws: SQLiteError.self) {
            _ = try value.integer()
        }
    }
}
