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
import Foundation
@testable import DXPostgres

@Suite struct PostgresDecodingTests {

    private struct Account: Decodable, Equatable {

        let id: Int
        let email: String
        let active: Bool
    }

    private struct Flag: Decodable, Equatable {

        let active: Bool
    }

    private struct WithTimestamp: Decodable {

        let id: Int
        let created: Date
    }

    private struct WithTags: Decodable {

        let id: Int
        let tags: [String]
    }

    private struct WithNested: Decodable {

        let id: Int
        let flag: Flag
    }

    private func column(_ name: String, _ oid: UInt32) -> PostgresColumn {
        PostgresColumn(name: name, dataTypeObjectID: oid, format: .text)
    }

    @Test func decodesRowsIntoDecodable() throws {
        let result = PostgresResult(
            columns: [column("id", 23), column("email", 25), column("active", 16)],
            rows: [
                [.bytes(Array("7".utf8)), .bytes(Array("a@b.com".utf8)), .bytes(Array("t".utf8))],
                [.bytes(Array("8".utf8)), .bytes(Array("c@d.com".utf8)), .bytes(Array("f".utf8))],
            ]
        )
        let accounts = try result.decode(as: Account.self)
        #expect(accounts == [Account(id: 7, email: "a@b.com", active: true), Account(id: 8, email: "c@d.com", active: false)])
    }

    @Test func cellReadersDistinguishNull() throws {
        #expect(PostgresCell.sqlNull.isNull)
        #expect(PostgresCell.bytes([]).isNull == false)
        #expect(try PostgresCell.bytes(Array("hello".utf8)).text() == "hello")
        #expect(try PostgresCell.bytes(Array("42".utf8)).bytes() == Array("42".utf8))
    }

    @Test func columnIndexLookup() throws {
        let result = PostgresResult(columns: [column("id", 23), column("email", 25)], rows: [])
        #expect(try result.columnIndex(named: "email") == 1)
    }

    @Test func decodesCanonicalBoolValues() throws {
        let result = PostgresResult(
            columns: [column("active", 16)],
            rows: [[.bytes(Array("t".utf8))], [.bytes(Array("f".utf8))]]
        )
        #expect(try result.decode(as: Flag.self) == [Flag(active: true), Flag(active: false)])
    }

    @Test func nonCanonicalBoolValueThrowsRatherThanCoercing() throws {
        let result = PostgresResult(columns: [column("active", 16)], rows: [[.bytes(Array("true".utf8))]])
        #expect(throws: PostgresError.self) {
            try result.decode(as: Flag.self)
        }
    }

    @Test func nullIntoNonNullableFieldThrowsRatherThanCrashing() throws {
        let result = PostgresResult(columns: [column("active", 16)], rows: [[.sqlNull]])
        #expect(throws: PostgresError.self) {
            try result.decode(as: Flag.self)
        }
    }

    @Test func emptyResultDecodesToEmptyArray() throws {
        let result = PostgresResult(columns: [column("active", 16)], rows: [])
        #expect(try result.decode(as: Flag.self).isEmpty)
    }

    @Test func missingColumnForAFieldThrowsRatherThanCrashing() {
        let result = PostgresResult(
            columns: [column("id", 23), column("email", 25)],
            rows: [[.bytes(Array("7".utf8)), .bytes(Array("a@b.com".utf8))]]
        )
        #expect(throws: PostgresError.self) { try result.decode(as: Account.self) }
    }

    @Test func extraColumnsBeyondTheTargetAreIgnored() throws {
        let result = PostgresResult(
            columns: [column("active", 16), column("note", 25)],
            rows: [[.bytes(Array("t".utf8)), .bytes(Array("ignored".utf8))]]
        )
        #expect(try result.decode(as: Flag.self) == [Flag(active: true)])
    }

    @Test func unsupportedFieldTypesThrowRatherThanCrashing() throws {
        let timestamp = PostgresResult(columns: [column("id", 23), column("created", 1114)], rows: [[.bytes(Array("1".utf8)), .bytes(Array("2026-01-01".utf8))]])
        #expect(throws: PostgresError.self) { try timestamp.decode(as: WithTimestamp.self) }

        let tags = PostgresResult(columns: [column("id", 23), column("tags", 1009)], rows: [[.bytes(Array("1".utf8)), .bytes(Array("{a,b}".utf8))]])
        #expect(throws: PostgresError.self) { try tags.decode(as: WithTags.self) }

        let nested = PostgresResult(columns: [column("id", 23), column("flag", 16)], rows: [[.bytes(Array("1".utf8)), .bytes(Array("t".utf8))]])
        #expect(throws: PostgresError.self) { try nested.decode(as: WithNested.self) }
    }
}
