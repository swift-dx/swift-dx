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
@testable import DXPostgres

@Suite struct PostgresDecodingTests {

    private struct Account: Decodable, Equatable {

        let id: Int
        let email: String
        let active: Bool
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
}
