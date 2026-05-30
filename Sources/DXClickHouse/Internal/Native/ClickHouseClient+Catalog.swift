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

// Convenience methods over `system.databases` and `system.tables` for
// the common production needs: listing databases, listing tables in a
// database, and checking table existence.
//
// All methods funnel through `collectDecodedRows` with server-side
// parameter substitution rather than string concatenation: the
// database/table names go in the parameters list, so they can't be
// interpreted as SQL syntax. The fallback `EXISTS TABLE <ident>` form
// requires raw identifiers (parameters can't substitute identifiers),
// so the safer `system.tables` path is used instead.
extension ClickHouseClient {

    public func databases() async throws(ClickHouseError) -> [String] {
        let (sql, parameters) = Self.buildDatabasesQuery()
        let rows = try await collectDecodedRows(sql, as: NameRow.self, parameters: parameters)
        return rows.map(\.name)
    }

    public func tables(in database: String) async throws(ClickHouseError) -> [String] {
        let (sql, parameters) = Self.buildTablesQuery(database: database)
        let rows = try await collectDecodedRows(sql, as: NameRow.self, parameters: parameters)
        return rows.map(\.name)
    }

    public func exists(table: String) async throws(ClickHouseError) -> Bool {
        let (sql, parameters) = Self.buildExistsQueryInCurrentDatabase(table: table)
        let rows = try await collectDecodedRows(sql, as: ExistsMarkerRow.self, parameters: parameters)
        return !rows.isEmpty
    }

    public func exists(table: String, in database: String) async throws(ClickHouseError) -> Bool {
        let (sql, parameters) = Self.buildExistsQueryInDatabase(table: table, database: database)
        let rows = try await collectDecodedRows(sql, as: ExistsMarkerRow.self, parameters: parameters)
        return !rows.isEmpty
    }

    public func describe(table: String) async throws(ClickHouseError) -> [ClickHouseColumnInfo] {
        let (sql, parameters) = Self.buildDescribeQueryInCurrentDatabase(table: table)
        return try await collectDecodedRows(sql, as: ClickHouseColumnInfo.self, parameters: parameters)
    }

    public func describe(table: String, in database: String) async throws(ClickHouseError) -> [ClickHouseColumnInfo] {
        let (sql, parameters) = Self.buildDescribeQueryInDatabase(table: table, database: database)
        return try await collectDecodedRows(sql, as: ClickHouseColumnInfo.self, parameters: parameters)
    }

    static func buildDatabasesQuery() -> (sql: String, parameters: [ClickHouseQueryParameter]) {
        ("SELECT name FROM system.databases ORDER BY name", [])
    }

    static func buildTablesQuery(database: String) -> (sql: String, parameters: [ClickHouseQueryParameter]) {
        let sql = "SELECT name FROM system.tables WHERE database = {db:String} ORDER BY name"
        let parameters = [ClickHouseQueryParameter.string(database, name: "db")]
        return (sql, parameters)
    }

    // When the caller doesn't specify a database, scope the lookup to
    // the connection's session database via CH's `currentDatabase()`
    // SQL function rather than hardcoding "default". A user that
    // connects with `database: "events"` expects `client.exists(table:
    // "logs")` to check `events.logs`, not `default.logs`. Hardcoding
    // "default" silently looked in the wrong database whenever the
    // connection wasn't on the default DB.
    static func buildExistsQueryInCurrentDatabase(table: String) -> (sql: String, parameters: [ClickHouseQueryParameter]) {
        let sql = "SELECT 1 AS marker FROM system.tables WHERE database = currentDatabase() AND name = {tbl:String} LIMIT 1"
        let parameters = [ClickHouseQueryParameter.string(table, name: "tbl")]
        return (sql, parameters)
    }

    static func buildExistsQueryInDatabase(table: String, database: String) -> (sql: String, parameters: [ClickHouseQueryParameter]) {
        let sql = "SELECT 1 AS marker FROM system.tables WHERE database = {db:String} AND name = {tbl:String} LIMIT 1"
        let parameters = [
            ClickHouseQueryParameter.string(database, name: "db"),
            ClickHouseQueryParameter.string(table, name: "tbl"),
        ]
        return (sql, parameters)
    }

    static func buildDescribeQueryInCurrentDatabase(table: String) -> (sql: String, parameters: [ClickHouseQueryParameter]) {
        let sql = "SELECT name, type, default_kind, default_expression, comment FROM system.columns WHERE database = currentDatabase() AND table = {tbl:String} ORDER BY position"
        let parameters = [ClickHouseQueryParameter.string(table, name: "tbl")]
        return (sql, parameters)
    }

    static func buildDescribeQueryInDatabase(table: String, database: String) -> (sql: String, parameters: [ClickHouseQueryParameter]) {
        let sql = "SELECT name, type, default_kind, default_expression, comment FROM system.columns WHERE database = {db:String} AND table = {tbl:String} ORDER BY position"
        let parameters = [
            ClickHouseQueryParameter.string(database, name: "db"),
            ClickHouseQueryParameter.string(table, name: "tbl"),
        ]
        return (sql, parameters)
    }

    private struct NameRow: Decodable {

        let name: String

    }

    private struct ExistsMarkerRow: Decodable {

        let marker: UInt8

    }

}
