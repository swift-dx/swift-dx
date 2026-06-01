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

import Testing

import DXPostgres

// Plain `import DXPostgres` (no @testable): this target can only touch the public
// surface, so it fails to compile the moment a public symbol is renamed, an init
// parameter changes, or a public enum gains or loses a case. It is the
// breaking-change tripwire for the API.

private struct FakeDatabase: PostgresQuerying {

    func query(_ sql: String) async throws(PostgresError) -> PostgresQueryResult { Self.sample }
    func query(_ sql: String, binding parameters: [any PostgresEncodable]) async throws(PostgresError) -> PostgresQueryResult { Self.sample }
    func query(_ query: PostgresQuery) async throws(PostgresError) -> PostgresQueryResult { Self.sample }

    static var sample: PostgresQueryResult {
        let column = PostgresColumn(name: "n", dataTypeObjectID: 23, format: .text)
        let row = PostgresRow(columns: [column], cells: [.bytes(Array("42".utf8))])
        return PostgresQueryResult(columns: [column], rows: [row], commandTag: PostgresCommandTag(raw: "SELECT 1"))
    }
}

private struct Celsius: PostgresDecodable {

    let degrees: Int

    static func decode(from value: PostgresDecodingValue) throws(PostgresError) -> Celsius {
        Celsius(degrees: try Int.decode(from: value))
    }
}

private struct Tag: PostgresEncodable {

    let value: String

    func encodeToText() throws(PostgresError) -> PostgresCell {
        try value.encodeToText()
    }
}

@Suite struct PublicSurfaceTests {

    @Test func buildsEveryConfigurationType() {
        _ = PostgresEndpoint(host: "localhost")
        _ = PostgresEndpoint(host: "localhost", port: 5433)
        _ = PostgresCredentials.trust(username: "u").username
        _ = PostgresCredentials.password(username: "u", password: "p").username
        _ = PostgresDatabaseName("db")
        _ = PostgresTransportSecurity.plaintext
        _ = PostgresTransportSecurity.tls(PostgresTLSConfiguration(serverName: .explicit("h"), trustRoots: .system, clientIdentity: .none))
        _ = PostgresResilience()
        _ = PostgresResilience.disabled
        _ = PostgresConfiguration(endpoint: PostgresEndpoint(host: "h"), credentials: .password(username: "u", password: "p"), database: PostgresDatabaseName("db"))
        _ = PostgresConfiguration(endpoints: [PostgresEndpoint(host: "h")], credentials: .trust(username: "u"), database: PostgresDatabaseName("db"))
    }

    @Test func buildsQueriesAndParameters() throws {
        _ = PostgresQuery("SELECT 1")
        _ = PostgresQuery("SELECT $1", parameters: [.sqlNull])
        _ = try PostgresNull().encodeToText()
        _ = try PostgresJSON(["a": 1]).encodeToText()
        _ = try Tag(value: "x").encodeToText()
    }

    @Test func mockClientReturnsDecodableRows() async throws {
        let database: some PostgresQuerying = FakeDatabase()
        let result = try await database.query("SELECT n")
        #expect(result.rowCount == 1)
        #expect(try result.rows[0].decode(Int.self, named: "n") == 42)
        #expect(try result.rows[0].decode(Celsius.self, named: "n").degrees == 42)
        #expect(result.commandTag.affectedRows == 1)
    }

    @Test func serverErrorExposesFields() {
        let error = PostgresServerError(severity: "ERROR", sqlState: "23505", message: "duplicate key")
        #expect(error.sqlState == "23505")
        #expect(error.value(of: .detail) == .absent)
    }

    @Test func errorCasesAreExhaustivelyMatchable() {
        #expect(!describe(PostgresError.connectionClosed).isEmpty)
        #expect(!describe(PostgresError.server(PostgresServerError(severity: "E", sqlState: "x", message: "m"))).isEmpty)
    }

    private func describe(_ error: PostgresError) -> String {
        switch error {
        case .connectionClosed: "connectionClosed"
        case .connectFailed(let reason): reason
        case .handshakeFailed(let reason): reason
        case .authenticationFailed(let reason): reason
        case .unsupportedAuthentication(let method): method
        case .tlsNotSupportedByServer: "tls"
        case .transportError(let reason): reason
        case .timedOut: "timedOut"
        case .protocolError(let reason): reason
        case .server(let serverError): serverError.message
        case .poolExhausted(let maxConnections): "\(maxConnections)"
        case .poolShutdown: "poolShutdown"
        case .poolHasNoEndpoints: "poolHasNoEndpoints"
        case .columnIndexOutOfRange(let index, let columnCount): "\(index)/\(columnCount)"
        case .columnNameNotFound(let name): name
        case .columnIsNull(let column): column
        case .typeDecodingFailed(let type, let reason): "\(type):\(reason)"
        case .parameterCountMismatch(let expected, let provided): "\(expected)/\(provided)"
        case .jsonEncodingFailed(let typeName, let reason): "\(typeName):\(reason)"
        case .jsonDecodingFailed(let typeName, let reason): "\(typeName):\(reason)"
        case .utf8DecodingFailed: "utf8DecodingFailed"
        case .cancelled: "cancelled"
        case .noCurrentClient: "noCurrentClient"
        }
    }

    @Test func dataTypeCasesAreExhaustivelyMatchable() {
        for objectID: UInt32 in [16, 23, 1700, 2950, 1184, 999_999] {
            #expect(!name(PostgresColumn(name: "c", dataTypeObjectID: objectID, format: .binary).dataType).isEmpty)
        }
    }

    private func name(_ dataType: PostgresDataType) -> String {
        switch dataType {
        case .bool: "bool"
        case .bytea: "bytea"
        case .int2: "int2"
        case .int4: "int4"
        case .int8: "int8"
        case .objectIdentifier: "oid"
        case .float4: "float4"
        case .float8: "float8"
        case .numeric: "numeric"
        case .text: "text"
        case .varchar: "varchar"
        case .bpchar: "bpchar"
        case .name: "name"
        case .json: "json"
        case .jsonb: "jsonb"
        case .uuid: "uuid"
        case .date: "date"
        case .time: "time"
        case .timestamp: "timestamp"
        case .timestamptz: "timestamptz"
        case .other(let objectID): "other(\(objectID))"
        }
    }

    @Test func valueShapesAreExhaustivelyMatchable() {
        for cell in [PostgresCell.sqlNull, PostgresCell.bytes([1])] {
            switch cell {
            case .sqlNull: #expect(Bool(true))
            case .bytes(let bytes): #expect(bytes.count >= 0)
            }
        }
        for value in [PostgresFieldValue.absent, PostgresFieldValue.present("x")] {
            switch value {
            case .absent: #expect(Bool(true))
            case .present(let text): #expect(!text.isEmpty)
            }
        }
        for column in [PostgresColumnValue<Int>.sqlNull, PostgresColumnValue<Int>.value(1)] {
            switch column {
            case .sqlNull: #expect(Bool(true))
            case .value(let number): #expect(number == 1)
            }
        }
        for format in [PostgresFormat.text, PostgresFormat.binary] {
            switch format {
            case .text: #expect(Bool(true))
            case .binary: #expect(Bool(true))
            }
        }
    }
}
