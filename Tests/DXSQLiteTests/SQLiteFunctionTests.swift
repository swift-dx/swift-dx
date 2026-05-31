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

@Suite("DXSQLite custom SQL functions")
struct SQLiteFunctionTests {

    @Test("a custom scalar function is callable from both readers and the writer")
    func scalarFunction() async throws {
        let doubler = SQLiteFunction(name: "double_it", argumentCount: 1) { arguments in
            guard let first = arguments.first, case .integer(let value) = first else { return .null }
            return .integer(value &* 2)
        }
        let path = NSTemporaryDirectory() + "dxsqlite-fn-\(UUID().uuidString).sqlite"
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 2, functions: [doubler]))

        try await database.write { writer in
            try writer.execute("CREATE TABLE n (v INTEGER NOT NULL)")
            _ = try writer.mutate("INSERT INTO n(v) VALUES (?)", parameters: [21])
        }

        let readerRows = try await database.read { reader in
            try reader.query("SELECT double_it(v) AS d FROM n")
        }
        #expect(try #require(readerRows.first).integer(named: "d") == 42)

        let writerRows = try await database.write { writer in
            try writer.query("SELECT double_it(100) AS d")
        }
        #expect(try #require(writerRows.first).integer(named: "d") == 200)

        await database.close()
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }
}
