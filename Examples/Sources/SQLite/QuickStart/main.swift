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

import DXSQLite
import Foundation

// Quick-start tour of the DXSQLite client. SQLite is embedded, so this runs
// with no server — just `swift run SQLiteQuickStart`.

struct Item: Codable, Sendable {

    let id: Int
    let name: String
    let price: Double
}

let path = NSTemporaryDirectory() + "dxsqlite-quickstart.sqlite"
let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

// One transaction creates the schema and seeds rows, committing atomically.
try await database.transaction { writer in
    try writer.execute("CREATE TABLE IF NOT EXISTS item (id INTEGER PRIMARY KEY, name TEXT NOT NULL, price REAL NOT NULL)")
    _ = try writer.mutate("INSERT INTO item (id, name, price) VALUES (?, ?, ?)", parameters: [1, "Keyboard", 49.99])
    _ = try writer.mutate("INSERT INTO item (id, name, price) VALUES (?, ?, ?)", parameters: [2, "Mouse", 24.5])
}

// Decode result rows straight into a Codable type.
let items = try await database.read { reader in
    try reader.query("SELECT id, name, price FROM item ORDER BY id", as: Item.self)
}
print("items:", items)

// Stream rows lazily; the reader is held only for the stream's lifetime.
var total = 0.0
for try await row in database.readStream("SELECT price FROM item") {
    total += try row.double(named: "price")
}
print("total price:", total)

// Bind the database ambiently so deep code reaches it without being handed it.
try await SQLite.withCurrent(database) {
    let current = try SQLite.current()
    let counts = try await current.read { reader in
        try reader.query("SELECT COUNT(*) AS c FROM item")
    }
    print("row count:", try counts[0].integer(named: "c"))
}

await database.close()
try? FileManager.default.removeItem(atPath: path)
try? FileManager.default.removeItem(atPath: path + "-wal")
try? FileManager.default.removeItem(atPath: path + "-shm")
print("done")
