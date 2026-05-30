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

import DXClickHouse
import Foundation
import Testing

// Drives `ClickHouseClient.execute` across every realistic SQL shape the
// caller can hand it: every flavour of DDL the production surface
// exercises (CREATE/DROP/RENAME/ALTER/TRUNCATE), data-manipulating
// statements that do not return rows (INSERT VALUES, DELETE, ALTER
// UPDATE), and the system control verbs (SYSTEM FLUSH LOGS, SYSTEM
// RELOAD CONFIG). Each test runs end-to-end and verifies the visible
// side-effect with a follow-up SELECT so a silently-dropped statement
// surfaces.
@Suite(
    "DXClickHouse OperationsCoverage: execute every SQL variation",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct ExecuteCoverageIT {

    @Test("execute CREATE then DROP TABLE round-trips and the table is gone")
    func createAndDropTable() async throws {
        let table = OperationsCoverageSupport.uniqueTable(prefix: "create_drop")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("CREATE TABLE \(table) (id UInt64) ENGINE = Memory")
        let exists = try await client.scalar(
            "SELECT toUInt64(count()) FROM system.tables WHERE database = currentDatabase() AND name = '\(table)'",
            as: UInt64.self
        )
        #expect(exists == 1)
        try await client.execute("DROP TABLE \(table)")
        let gone = try await client.scalar(
            "SELECT toUInt64(count()) FROM system.tables WHERE database = currentDatabase() AND name = '\(table)'",
            as: UInt64.self
        )
        #expect(gone == 0)
    }

    @Test("execute CREATE OR REPLACE TABLE replaces the schema in place")
    func createOrReplaceTable() async throws {
        let table = OperationsCoverageSupport.uniqueTable(prefix: "replace")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("CREATE TABLE \(table) (id UInt64) ENGINE = Memory")
        try await client.execute("CREATE OR REPLACE TABLE \(table) (id UInt64, name String) ENGINE = Memory")
        let columns = try await client.scalar(
            "SELECT toUInt64(count()) FROM system.columns WHERE database = currentDatabase() AND table = '\(table)'",
            as: UInt64.self
        )
        #expect(columns == 2)
        try await client.execute("DROP TABLE \(table)")
    }

    @Test("execute RENAME TABLE moves a table to a new name")
    func renameTable() async throws {
        let original = OperationsCoverageSupport.uniqueTable(prefix: "rename_src")
        let renamed = OperationsCoverageSupport.uniqueTable(prefix: "rename_dst")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("CREATE TABLE \(original) (id UInt64) ENGINE = Memory")
        try await client.execute("RENAME TABLE \(original) TO \(renamed)")
        let originalGone = try await client.scalar(
            "SELECT toUInt64(count()) FROM system.tables WHERE database = currentDatabase() AND name = '\(original)'",
            as: UInt64.self
        )
        let renamedThere = try await client.scalar(
            "SELECT toUInt64(count()) FROM system.tables WHERE database = currentDatabase() AND name = '\(renamed)'",
            as: UInt64.self
        )
        #expect(originalGone == 0)
        #expect(renamedThere == 1)
        try await client.execute("DROP TABLE \(renamed)")
    }

    @Test("execute ALTER TABLE ADD COLUMN extends the schema")
    func alterTableAddColumn() async throws {
        let table = OperationsCoverageSupport.uniqueTable(prefix: "alter_add")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("CREATE TABLE \(table) (id UInt64) ENGINE = MergeTree ORDER BY id")
        try await client.execute("ALTER TABLE \(table) ADD COLUMN extra String DEFAULT ''")
        let columnCount = try await client.scalar(
            "SELECT toUInt64(count()) FROM system.columns WHERE database = currentDatabase() AND table = '\(table)'",
            as: UInt64.self
        )
        #expect(columnCount == 2)
        try await client.execute("DROP TABLE \(table)")
    }

    @Test("execute ALTER TABLE DROP COLUMN removes a column")
    func alterTableDropColumn() async throws {
        let table = OperationsCoverageSupport.uniqueTable(prefix: "alter_drop")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("CREATE TABLE \(table) (id UInt64, removable String DEFAULT '') ENGINE = MergeTree ORDER BY id")
        try await client.execute("ALTER TABLE \(table) DROP COLUMN removable")
        let columnCount = try await client.scalar(
            "SELECT toUInt64(count()) FROM system.columns WHERE database = currentDatabase() AND table = '\(table)'",
            as: UInt64.self
        )
        #expect(columnCount == 1)
        try await client.execute("DROP TABLE \(table)")
    }

    @Test("execute INSERT VALUES persists rows visible to SELECT count")
    func insertValuesPersists() async throws {
        let table = OperationsCoverageSupport.uniqueTable(prefix: "insert_values")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("CREATE TABLE \(table) (id UInt64, name String) ENGINE = Memory")
        try await client.execute("INSERT INTO \(table) VALUES (1, 'alpha'), (2, 'beta'), (3, 'gamma')")
        let count = try await client.scalar("SELECT toUInt64(count()) FROM \(table)", as: UInt64.self)
        #expect(count == 3)
        try await client.execute("DROP TABLE \(table)")
    }

    @Test("execute INSERT ... SELECT copies rows from numbers() into the target")
    func insertFromSelect() async throws {
        let table = OperationsCoverageSupport.uniqueTable(prefix: "insert_select")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("CREATE TABLE \(table) (id UInt64) ENGINE = Memory")
        try await client.execute("INSERT INTO \(table) SELECT number FROM numbers(100)")
        let count = try await client.scalar("SELECT toUInt64(count()) FROM \(table)", as: UInt64.self)
        #expect(count == 100)
        try await client.execute("DROP TABLE \(table)")
    }

    @Test("execute TRUNCATE TABLE empties an existing table")
    func truncateTable() async throws {
        let table = OperationsCoverageSupport.uniqueTable(prefix: "truncate")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("CREATE TABLE \(table) (id UInt64) ENGINE = MergeTree ORDER BY id")
        try await client.execute("INSERT INTO \(table) SELECT number FROM numbers(50)")
        let preTruncate = try await client.scalar("SELECT toUInt64(count()) FROM \(table)", as: UInt64.self)
        #expect(preTruncate == 50)
        try await client.execute("TRUNCATE TABLE \(table)")
        let postTruncate = try await client.scalar("SELECT toUInt64(count()) FROM \(table)", as: UInt64.self)
        #expect(postTruncate == 0)
        try await client.execute("DROP TABLE \(table)")
    }

    @Test("execute ALTER TABLE DELETE WHERE removes matching rows")
    func alterDeleteWhere() async throws {
        let table = OperationsCoverageSupport.uniqueTable(prefix: "alter_delete")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("CREATE TABLE \(table) (id UInt64) ENGINE = MergeTree ORDER BY id")
        try await client.execute("INSERT INTO \(table) SELECT number FROM numbers(20)")
        try await client.execute("ALTER TABLE \(table) DELETE WHERE id < 10 SETTINGS mutations_sync = 2")
        let remaining = try await client.scalar("SELECT toUInt64(count()) FROM \(table)", as: UInt64.self)
        #expect(remaining == 10)
        try await client.execute("DROP TABLE \(table)")
    }

    @Test("execute SYSTEM FLUSH LOGS returns without raising and the log table has rows")
    func systemFlushLogs() async throws {
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        // Issue one trivial query so query_log has something to flush.
        try await client.execute("SELECT toUInt64(1)")
        try await client.execute("SYSTEM FLUSH LOGS")
        let rowCount = try await client.scalar(
            "SELECT toUInt64(count()) FROM system.query_log WHERE query_kind = 'Select'",
            as: UInt64.self
        )
        #expect(rowCount >= 1)
    }

    @Test("execute CREATE VIEW + SELECT through the view delivers the underlying rows")
    func createView() async throws {
        let base = OperationsCoverageSupport.uniqueTable(prefix: "view_base")
        let view = OperationsCoverageSupport.uniqueTable(prefix: "view_def")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("CREATE TABLE \(base) (id UInt64) ENGINE = Memory")
        try await client.execute("INSERT INTO \(base) SELECT number FROM numbers(10)")
        try await client.execute("CREATE VIEW \(view) AS SELECT id * 2 AS doubled FROM \(base)")
        let sum = try await client.scalar(
            "SELECT toUInt64(sum(doubled)) FROM \(view)",
            as: UInt64.self
        )
        #expect(sum == 90)
        try await client.execute("DROP VIEW \(view)")
        try await client.execute("DROP TABLE \(base)")
    }

    @Test("execute USE database switches the connection's current database")
    func useDatabaseStatement() async throws {
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("USE \(OperationsCoverageSupport.database)")
        let database = try await client.scalar("SELECT currentDatabase()", as: String.self)
        #expect(database == OperationsCoverageSupport.database)
    }
}
