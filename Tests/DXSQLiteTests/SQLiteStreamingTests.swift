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

@Suite("DXSQLite streamed reads")
struct SQLiteStreamingTests {

    @Test("readStream yields every row in order")
    func streamsEveryRow() async throws {
        let path = NSTemporaryDirectory() + "dxsqlite-\(UUID().uuidString).sqlite"
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await database.write { writer in
            try writer.execute("CREATE TABLE n (v INTEGER NOT NULL)")
            for value in 1...100 {
                _ = try writer.mutate("INSERT INTO n(v) VALUES (?)", parameters: [.integer(Int64(value))])
            }
        }

        var collected: [Int64] = []
        for try await row in database.readStream("SELECT v FROM n ORDER BY v") {
            collected.append(try row.integer(named: "v"))
        }

        #expect(collected.count == 100)
        #expect(collected.first == 1)
        #expect(collected.last == 100)

        await database.close()
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }
}
