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

@Suite("DXSQLite reader pool backpressure")
struct SQLiteReaderPoolTests {

    @Test("more concurrent reads than readers all complete by waiting")
    func readsBeyondCapacityWait() async throws {
        let path = NSTemporaryDirectory() + "dxsqlite-\(UUID().uuidString).sqlite"
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 2))
        try await database.write { writer in
            try writer.execute("CREATE TABLE t (v INTEGER NOT NULL)")
            _ = try writer.mutate("INSERT INTO t(v) VALUES (1)", parameters: [])
        }

        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await database.read { reader in
                        let rows = try reader.query("SELECT COUNT(*) AS c FROM t")
                        guard case .integer(let count) = try rows[0].value(named: "c") else { return -1 }
                        return Int(count)
                    }
                }
            }
            var collected: [Int] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        #expect(results.count == 6)
        #expect(results.allSatisfy { $0 == 1 })

        await database.close()
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }
}
