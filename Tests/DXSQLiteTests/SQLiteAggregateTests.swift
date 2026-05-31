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

@Suite("DXSQLite custom aggregate functions")
struct SQLiteAggregateTests {

    final class ProductAggregator: SQLiteAggregator {

        private var product: Int64 = 1

        func step(_ arguments: [SQLiteValue]) throws {
            guard let first = arguments.first, case .integer(let value) = first else { return }
            product &*= value
        }

        func finalize() throws -> SQLiteValue {
            .integer(product)
        }
    }

    @Test("a custom aggregate folds rows on a pooled reader")
    func aggregate() async throws {
        let product = SQLiteAggregate(name: "product", argumentCount: 1) { ProductAggregator() }
        let path = NSTemporaryDirectory() + "dxsqlite-agg-\(UUID().uuidString).sqlite"
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), aggregates: [product]))

        try await database.write { writer in
            try writer.execute("CREATE TABLE n (v INTEGER NOT NULL)")
            for value in [2, 3, 4, 5] {
                _ = try writer.mutate("INSERT INTO n(v) VALUES (?)", parameters: [.integer(Int64(value))])
            }
        }

        let rows = try await database.read { reader in
            try reader.query("SELECT product(v) AS p FROM n")
        }
        #expect(try #require(rows.first).integer(named: "p") == 120)

        await database.close()
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }
}
