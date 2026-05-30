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

@testable import DXClickHouse
import Foundation
import Testing

@Suite("ClickHouseClient — system catalog convenience queries")
struct ClickHouseClientCatalogTests {

    @Test("buildDatabasesQuery emits the canonical sorted query against system.databases with no parameters")
    func buildDatabasesQuery() {
        let (sql, parameters) = ClickHouseClient.buildDatabasesQuery()
        #expect(sql == "SELECT name FROM system.databases ORDER BY name")
        #expect(parameters.isEmpty)
    }

    @Test("buildTablesQuery substitutes the database name via a server-side parameter, not concatenation")
    func buildTablesQuerySubstitutesViaParameter() {
        let (sql, parameters) = ClickHouseClient.buildTablesQuery(database: "default")
        #expect(sql == "SELECT name FROM system.tables WHERE database = {db:String} ORDER BY name")
        #expect(parameters.count == 1)
        #expect(parameters[0].name == "db")
        // Parameter values for `{name:String}` are encoded as Field-
        // dump-formatted single-quoted literals on the wire so the
        // server's BaseSettings::read can restore them as a String
        // Field. Without quotes the server throws "Couldn't restore
        // Field from dump: <value>".
        #expect(parameters[0].value == "'default'")
    }

    @Test("buildTablesQuery escapes embedded single quotes and backslashes per the SQL Field-dump format")
    func buildTablesQueryEscapesSpecialCharacters() {
        let (_, parameters) = ClickHouseClient.buildTablesQuery(database: "with'quote\\and-dashes")
        // Embedded single quotes become \\' on the wire; embedded
        // backslashes become \\\\. The wrapping single quotes mark
        // the whole value as a String literal for the server's
        // Field-restore path.
        #expect(parameters[0].value == "'with\\'quote\\\\and-dashes'")
    }

    @Test("buildExistsQuery without a database scopes the lookup to currentDatabase() so the connection's session database is honored")
    func buildExistsQueryWithoutDatabaseUsesCurrentDatabase() {
        // Pre-fix: the helper hardcoded the literal "default" database
        // when the caller passed nil. A user that connected with
        // `database: "events"` and called `exists(table: "logs")` would
        // silently query `default.logs` instead of `events.logs`. The
        // fix delegates to CH's `currentDatabase()` SQL function so
        // the lookup follows whatever database the connection's hello
        // negotiated, regardless of what value that turns out to be.
        let (sql, parameters) = ClickHouseClient.buildExistsQueryInCurrentDatabase(table: "events")
        #expect(sql.contains("system.tables"))
        #expect(sql.contains("LIMIT 1"))
        #expect(sql.contains("database = currentDatabase()"))
        #expect(!sql.contains("{db:String}"), "the db parameter must be omitted when no explicit database is given")
        #expect(parameters.count == 1)
        let tblParam = parameters.first { $0.name == "tbl" }
        #expect(tblParam?.value == "'events'")
    }

    @Test("buildExistsQuery with an explicit database uses that database in the parameter list")
    func buildExistsQueryUsesExplicitDatabase() {
        let (_, parameters) = ClickHouseClient.buildExistsQueryInDatabase(table: "events", database: "analytics")
        let dbParam = parameters.first { $0.name == "db" }
        #expect(dbParam?.value == "'analytics'")
    }

    @Test("buildExistsQuery uses {db:String} and {tbl:String} placeholders so the server validates types")
    func buildExistsQueryUsesTypedPlaceholders() {
        let (sql, _) = ClickHouseClient.buildExistsQueryInDatabase(table: "events", database: "analytics")
        #expect(sql.contains("{db:String}"))
        #expect(sql.contains("{tbl:String}"))
    }

    @Test("none of the catalog queries embed identifiers via string concatenation (SQL-injection-safe)")
    func catalogQueriesAreInjectionSafe() {
        let malicious = "default'; DROP TABLE users; --"
        let (tablesSQL, tablesParams) = ClickHouseClient.buildTablesQuery(database: malicious)
        let (existsSQL, existsParams) = ClickHouseClient.buildExistsQueryInDatabase(table: "events", database: malicious)
        let (describeSQL, describeParams) = ClickHouseClient.buildDescribeQueryInDatabase(table: "events", database: malicious)
        // None of the SQL strings should contain the malicious payload
        // literally — it only appears in the (escaped, quoted)
        // parameter values, which the server treats as a String Field.
        #expect(!tablesSQL.contains(malicious))
        #expect(!existsSQL.contains(malicious))
        #expect(!describeSQL.contains(malicious))
        // The payload's embedded quote is escaped; the closing semicolon
        // and DROP TABLE are inside the String literal so the server
        // never executes them.
        let escapedQuoted = "'default\\'; DROP TABLE users; --'"
        #expect(tablesParams.contains(where: { $0.value == escapedQuoted }))
        #expect(existsParams.contains(where: { $0.value == escapedQuoted }))
        #expect(describeParams.contains(where: { $0.value == escapedQuoted }))
    }

    @Test("buildDescribeQuery without a database scopes the lookup to currentDatabase() so the connection's session database is honored")
    func buildDescribeQueryWithoutDatabaseUsesCurrentDatabase() {
        // Same fix as buildExistsQuery: nil database now uses CH's
        // `currentDatabase()` SQL function rather than hardcoding
        // "default", honoring whatever database the connection's hello
        // negotiated.
        let (sql, parameters) = ClickHouseClient.buildDescribeQueryInCurrentDatabase(table: "events")
        #expect(sql.contains("database = currentDatabase()"))
        #expect(!sql.contains("{db:String}"), "the db parameter must be omitted when no explicit database is given")
        #expect(parameters.count == 1)
        let tblParam = parameters.first { $0.name == "tbl" }
        #expect(tblParam?.value == "'events'")
    }

    @Test("buildDescribeQuery selects the documented column subset and orders by position")
    func buildDescribeQuerySelectsCorrectColumns() {
        let (sql, _) = ClickHouseClient.buildDescribeQueryInDatabase(table: "events", database: "analytics")
        // Required columns
        for column in ["name", "type", "default_kind", "default_expression", "comment"] {
            #expect(sql.contains(column), "describe query must SELECT '\(column)'")
        }
        // Source table
        #expect(sql.contains("system.columns"))
        // Order
        #expect(sql.contains("ORDER BY position"))
    }

    @Test("buildDescribeQuery uses {db:String} and {tbl:String} placeholders")
    func buildDescribeQueryUsesTypedPlaceholders() {
        let (sql, _) = ClickHouseClient.buildDescribeQueryInDatabase(table: "events", database: "analytics")
        #expect(sql.contains("{db:String}"))
        #expect(sql.contains("{tbl:String}"))
    }

    @Test("ClickHouseColumnInfo decodes JSONEachRow row with snake_case fields into camelCase properties")
    func columnInfoDecodesSnakeCaseFields() throws {
        let json = """
        {"name":"id","type":"UInt64","default_kind":"DEFAULT","default_expression":"now()","comment":"primary key"}
        """
        let info = try JSONDecoder().decode(ClickHouseColumnInfo.self, from: Data(json.utf8))
        #expect(info.name == "id")
        #expect(info.type == "UInt64")
        #expect(info.defaultKind == "DEFAULT")
        #expect(info.defaultExpression == "now()")
        #expect(info.comment == "primary key")
    }

    @Test("ClickHouseColumnInfo decodes a row with empty default_kind / default_expression / comment (typical case)")
    func columnInfoDecodesEmptyOptionalFields() throws {
        let json = """
        {"name":"label","type":"String","default_kind":"","default_expression":"","comment":""}
        """
        let info = try JSONDecoder().decode(ClickHouseColumnInfo.self, from: Data(json.utf8))
        #expect(info.defaultKind == "")
        #expect(info.defaultExpression == "")
        #expect(info.comment == "")
    }

    @Test("ClickHouseColumnInfo equality compares all five fields")
    func columnInfoEquality() {
        let a = ClickHouseColumnInfo(name: "x", type: "Int32", defaultKind: "", defaultExpression: "", comment: "")
        let b = ClickHouseColumnInfo(name: "x", type: "Int32", defaultKind: "", defaultExpression: "", comment: "")
        #expect(a == b)
        let differentType = ClickHouseColumnInfo(name: "x", type: "Int64", defaultKind: "", defaultExpression: "", comment: "")
        #expect(a != differentType)
    }

}
