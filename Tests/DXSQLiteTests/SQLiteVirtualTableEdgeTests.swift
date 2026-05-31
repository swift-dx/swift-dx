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

@Suite("DXSQLite virtual table and FTS5 edge cases")
struct SQLiteVirtualTableEdgeTests {

    static let prefix = "dxsqlite-vtabedge"

    static func makePath() -> String {
        NSTemporaryDirectory() + "\(prefix)-\(UUID().uuidString).sqlite"
    }

    static func cleanUp(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    struct PriceTier: Sendable, Equatable {

        let identifier: Int64
        let label: String
        let multiplier: Double
    }

    struct ComputedTierTable: SQLiteTableProvider {

        let name: String
        let schema: String
        let tiers: [PriceTier]

        init(name: String, tiers: [PriceTier]) {
            self.name = name
            self.schema = "CREATE TABLE \(name)(identifier, label, multiplier)"
            self.tiers = tiers
        }

        func rows() -> [[SQLiteValue]] {
            tiers.map { tier in
                [.integer(tier.identifier), .text(tier.label), .real(tier.multiplier)]
            }
        }
    }

    @Test("a static virtual table with zero rows yields zero results")
    func emptyStaticTableYieldsNoRows() async throws {
        let path = Self.makePath()
        let provider = SQLiteStaticTable(name: "warehouses", columns: ["id", "region"], rows: [])
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), virtualTables: [provider]))

        let rows = try await database.read { reader in
            try reader.query("SELECT id, region FROM warehouses")
        }
        #expect(rows.isEmpty)

        let total = try await database.read { reader in
            try reader.query("SELECT COUNT(*) AS n FROM warehouses")
        }
        #expect(try total[0].integer(named: "n") == 0)

        await database.close()
        Self.cleanUp(path)
    }

    @Test("a column beyond a short row's values reads as NULL without crashing")
    func shortRowYieldsNullForMissingColumn() async throws {
        let path = Self.makePath()
        let provider = SQLiteStaticTable(
            name: "catalog",
            columns: ["sku", "title", "discount"],
            rows: [
                [.text("SKU-001"), .text("Wireless Charger")],
                [.text("SKU-002"), .text("Desk Lamp"), .real(0.15)],
            ]
        )
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), virtualTables: [provider]))

        let rows = try await database.read { reader in
            try reader.query("SELECT sku, title, discount FROM catalog ORDER BY sku")
        }
        #expect(rows.count == 2)
        #expect(try rows[0].value(named: "discount") == SQLiteValue.null)
        #expect(try rows[0].text(named: "title") == "Wireless Charger")
        #expect(try rows[1].value(named: "discount") == SQLiteValue.real(0.15))

        await database.close()
        Self.cleanUp(path)
    }

    @Test("a static column carrying different value kinds across rows reads each cell independently")
    func mixedValueKindsInOneColumn() async throws {
        let path = Self.makePath()
        let provider = SQLiteStaticTable(
            name: "attributes",
            columns: ["key", "value"],
            rows: [
                [.text("count"), .integer(42)],
                [.text("ratio"), .real(0.5)],
                [.text("name"), .text("standard")],
                [.text("absent"), .null],
                [.text("payload"), .blob([0x01, 0x02, 0x03])],
            ]
        )
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), virtualTables: [provider]))

        let rows = try await database.read { reader in
            try reader.query("SELECT key, value FROM attributes ORDER BY key")
        }
        #expect(rows.count == 5)

        let byKey = try Dictionary(uniqueKeysWithValues: rows.map { row in
            try (row.text(named: "key"), row.value(named: "value"))
        })
        #expect(byKey["count"] == SQLiteValue.integer(42))
        #expect(byKey["ratio"] == SQLiteValue.real(0.5))
        #expect(byKey["name"] == SQLiteValue.text("standard"))
        #expect(byKey["absent"] == SQLiteValue.null)
        #expect(byKey["payload"] == SQLiteValue.blob([0x01, 0x02, 0x03]))

        await database.close()
        Self.cleanUp(path)
    }

    @Test("a custom table provider supports WHERE, ORDER BY, and COUNT(*)")
    func customProviderSupportsFilteringOrderingAndCount() async throws {
        let path = Self.makePath()
        let provider = ComputedTierTable(
            name: "tiers",
            tiers: [
                PriceTier(identifier: 1, label: "bronze", multiplier: 1.0),
                PriceTier(identifier: 2, label: "silver", multiplier: 1.25),
                PriceTier(identifier: 3, label: "gold", multiplier: 1.6),
            ]
        )
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), virtualTables: [provider]))

        let ordered = try await database.read { reader in
            try reader.query("SELECT label FROM tiers ORDER BY multiplier DESC")
        }
        #expect(ordered.count == 3)
        #expect(try ordered[0].text(named: "label") == "gold")
        #expect(try ordered[2].text(named: "label") == "bronze")

        let filtered = try await database.read { reader in
            try reader.query("SELECT identifier, label FROM tiers WHERE multiplier > ? ORDER BY identifier", parameters: [.real(1.0)])
        }
        #expect(filtered.count == 2)
        #expect(try filtered[0].text(named: "label") == "silver")
        #expect(try filtered[1].text(named: "label") == "gold")

        let total = try await database.read { reader in
            try reader.query("SELECT COUNT(*) AS n FROM tiers")
        }
        #expect(try total[0].integer(named: "n") == 3)

        await database.close()
        Self.cleanUp(path)
    }

    @Test("FTS5 MATCH resolves AND, OR, and NOT boolean queries to the right documents")
    func fullTextBooleanQueries() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            try writer.execute("CREATE VIRTUAL TABLE documents USING fts5(title, body)")
            _ = try writer.mutate("INSERT INTO documents(title, body) VALUES ('alpha', 'shipping invoice for warehouse goods')", parameters: [])
            _ = try writer.mutate("INSERT INTO documents(title, body) VALUES ('beta', 'invoice payment receipt archive')", parameters: [])
            _ = try writer.mutate("INSERT INTO documents(title, body) VALUES ('gamma', 'warehouse inventory stock report')", parameters: [])
        }

        let andRows = try await database.read { reader in
            try reader.query("SELECT title FROM documents WHERE documents MATCH ? ORDER BY title", parameters: [.text("invoice AND warehouse")])
        }
        #expect(andRows.count == 1)
        #expect(try andRows[0].text(named: "title") == "alpha")

        let orRows = try await database.read { reader in
            try reader.query("SELECT title FROM documents WHERE documents MATCH ? ORDER BY title", parameters: [.text("payment OR inventory")])
        }
        #expect(orRows.count == 2)
        #expect(try orRows[0].text(named: "title") == "beta")
        #expect(try orRows[1].text(named: "title") == "gamma")

        let notRows = try await database.read { reader in
            try reader.query("SELECT title FROM documents WHERE documents MATCH ? ORDER BY title", parameters: [.text("warehouse NOT invoice")])
        }
        #expect(notRows.count == 1)
        #expect(try notRows[0].text(named: "title") == "gamma")

        await database.close()
        Self.cleanUp(path)
    }

    @Test("FTS5 rank orders the most relevant document first")
    func fullTextRankOrdering() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            try writer.execute("CREATE VIRTUAL TABLE articles USING fts5(title, body)")
            _ = try writer.mutate("INSERT INTO articles(title, body) VALUES ('mention', 'a single refund mention in passing')", parameters: [])
            _ = try writer.mutate("INSERT INTO articles(title, body) VALUES ('focused', 'refund policy refund window refund processing refund timing')", parameters: [])
        }

        let ranked = try await database.read { reader in
            try reader.query("SELECT title FROM articles WHERE articles MATCH ? ORDER BY rank", parameters: [.text("refund")])
        }
        #expect(ranked.count == 2)
        #expect(try ranked[0].text(named: "title") == "focused")
        #expect(try ranked[1].text(named: "title") == "mention")

        await database.close()
        Self.cleanUp(path)
    }

    @Test("FTS5 reindexes on UPDATE so MATCH reflects the new text")
    func fullTextReindexOnUpdate() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            try writer.execute("CREATE VIRTUAL TABLE notes USING fts5(label, content)")
            _ = try writer.mutate("INSERT INTO notes(label, content) VALUES ('order', 'pending fulfillment queue')", parameters: [])
        }

        let beforeUpdate = try await database.read { reader in
            try reader.query("SELECT label FROM notes WHERE notes MATCH ?", parameters: [.text("pending")])
        }
        #expect(beforeUpdate.count == 1)

        try await database.write { writer in
            _ = try writer.mutate("UPDATE notes SET content = ? WHERE label = ?", parameters: [.text("shipped tracking confirmed"), .text("order")])
        }

        let staleMatch = try await database.read { reader in
            try reader.query("SELECT label FROM notes WHERE notes MATCH ?", parameters: [.text("pending")])
        }
        #expect(staleMatch.isEmpty)

        let freshMatch = try await database.read { reader in
            try reader.query("SELECT label FROM notes WHERE notes MATCH ?", parameters: [.text("shipped")])
        }
        #expect(freshMatch.count == 1)
        #expect(try freshMatch[0].text(named: "label") == "order")

        await database.close()
        Self.cleanUp(path)
    }

    @Test("FTS5 reindexes on DELETE so the removed document no longer matches")
    func fullTextReindexOnDelete() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            try writer.execute("CREATE VIRTUAL TABLE entries USING fts5(label, content)")
            _ = try writer.mutate("INSERT INTO entries(label, content) VALUES ('first', 'subscription renewal reminder')", parameters: [])
            _ = try writer.mutate("INSERT INTO entries(label, content) VALUES ('second', 'subscription cancellation notice')", parameters: [])
        }

        let beforeDelete = try await database.read { reader in
            try reader.query("SELECT label FROM entries WHERE entries MATCH ? ORDER BY label", parameters: [.text("subscription")])
        }
        #expect(beforeDelete.count == 2)

        try await database.write { writer in
            _ = try writer.mutate("DELETE FROM entries WHERE label = ?", parameters: [.text("first")])
        }

        let afterDelete = try await database.read { reader in
            try reader.query("SELECT label FROM entries WHERE entries MATCH ? ORDER BY label", parameters: [.text("subscription")])
        }
        #expect(afterDelete.count == 1)
        #expect(try afterDelete[0].text(named: "label") == "second")

        let removedMatch = try await database.read { reader in
            try reader.query("SELECT label FROM entries WHERE entries MATCH ?", parameters: [.text("renewal")])
        }
        #expect(removedMatch.isEmpty)

        await database.close()
        Self.cleanUp(path)
    }
}
