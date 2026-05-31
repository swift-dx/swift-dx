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

@Suite("DXSQLite Codable row decoding")
struct SQLiteDecodingTests {

    struct Item: Decodable, Equatable {
        let id: Int
        let name: String
        let active: Bool
    }

    struct Meta: Codable, Equatable {
        let tags: [String]
    }

    struct Document: Decodable, Equatable {
        let id: Int
        let meta: Meta
    }

    @Test("scalar columns decode into a struct")
    func decodesScalars() async throws {
        let path = NSTemporaryDirectory() + "dxsqlite-\(UUID().uuidString).sqlite"
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await database.write { writer in
            try writer.execute("CREATE TABLE item (id INTEGER, name TEXT, active INTEGER)")
            _ = try writer.mutate("INSERT INTO item (id, name, active) VALUES (1, 'Ada', 1)", parameters: [])
            _ = try writer.mutate("INSERT INTO item (id, name, active) VALUES (2, 'Bo', 0)", parameters: [])
        }

        let items = try await database.read { reader in
            try reader.query("SELECT id, name, active FROM item ORDER BY id", as: Item.self)
        }
        #expect(items == [Item(id: 1, name: "Ada", active: true), Item(id: 2, name: "Bo", active: false)])

        await database.close()
        Self.cleanUp(path)
    }

    @Test("a nested Codable value decodes from a JSON text column")
    func decodesJSONColumn() async throws {
        let path = NSTemporaryDirectory() + "dxsqlite-\(UUID().uuidString).sqlite"
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await database.write { writer in
            try writer.execute("CREATE TABLE doc (id INTEGER, meta TEXT)")
            _ = try writer.mutate("INSERT INTO doc (id, meta) VALUES (?, ?)", parameters: [.integer(1), .text("{\"tags\":[\"a\",\"b\"]}")])
        }

        let docs = try await database.read { reader in
            try reader.query("SELECT id, meta FROM doc", as: Document.self)
        }
        #expect(docs == [Document(id: 1, meta: Meta(tags: ["a", "b"]))])

        await database.close()
        Self.cleanUp(path)
    }

    private static func cleanUp(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }
}
