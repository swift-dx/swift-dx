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

@Suite struct PostgresStatementTests {

    @Test func interpolationBindsParametersInOrder() {
        let email = "alice@example.com"
        let statement: PostgresStatement = "SELECT id FROM users WHERE email = \(email) AND age > \(30)"
        #expect(statement.sql == "SELECT id FROM users WHERE email = $1 AND age > $2")
        #expect(statement.bindings == [.bytes(Array("alice@example.com".utf8)), .bytes(Array("30".utf8))])
    }

    @Test func literalHasNoBindings() {
        let statement: PostgresStatement = "SELECT 1"
        #expect(statement.sql == "SELECT 1")
        #expect(statement.bindings.isEmpty)
    }

    @Test func injectionStringIsBoundNeverSpliced() {
        let evil = "x'); DROP TABLE users;--"
        let statement: PostgresStatement = "SELECT * FROM users WHERE name = \(evil)"
        #expect(statement.sql == "SELECT * FROM users WHERE name = $1")
        #expect(statement.bindings == [.bytes(Array(evil.utf8))])
    }

    @Test func boolBindsAsServerLiteral() {
        let statement: PostgresStatement = "WHERE active = \(true) OR flagged = \(false)"
        #expect(statement.sql == "WHERE active = $1 OR flagged = $2")
        #expect(statement.bindings == [.bytes(Array("t".utf8)), .bytes(Array("f".utf8))])
    }
}
