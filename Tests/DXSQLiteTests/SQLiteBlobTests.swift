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

@Suite("DXSQLite incremental blob I/O")
struct SQLiteBlobTests {

    @Test("a pre-sized blob cell is written and read back incrementally")
    func blobRoundTrip() async throws {
        let path = NSTemporaryDirectory() + "dxsqlite-blob-\(UUID().uuidString).sqlite"
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        let payload: [UInt8] = [10, 20, 30, 40, 50]

        let rowID = try await database.write { writer -> Int64 in
            try writer.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, data BLOB NOT NULL)")
            _ = try writer.mutate("INSERT INTO t(data) VALUES (zeroblob(?))", parameters: [.integer(Int64(payload.count))])
            let identifier = writer.lastInsertRowID
            try writer.withBlob(table: "t", column: "data", rowID: identifier) { blob in
                try blob.write(payload, at: 0)
            }
            return identifier
        }

        let readBack = try await database.read { reader -> [UInt8] in
            try reader.withBlob(table: "t", column: "data", rowID: rowID) { blob in
                try blob.read(count: blob.count, at: 0)
            }
        }
        #expect(readBack == payload)

        await database.close()
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }
}
