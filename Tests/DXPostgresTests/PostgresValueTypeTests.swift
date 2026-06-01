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

@Suite struct PostgresValueTypeTests {

    @Test(arguments: [
        ("INSERT 0 3", 3),
        ("UPDATE 5", 5),
        ("DELETE 2", 2),
        ("SELECT 10", 10),
        ("CREATE TABLE", 0),
        ("", 0),
    ])
    func commandTagExtractsAffectedRows(_ raw: String, _ expected: Int) {
        #expect(PostgresCommandTag(raw: raw).affectedRows == expected)
    }

    @Test func encodableValuesRenderAsText() throws {
        #expect(try Int(42).encodeToText() == .bytes(Array("42".utf8)))
        #expect(try "hi".encodeToText() == .bytes(Array("hi".utf8)))
        #expect(try true.encodeToText() == .bytes(Array("true".utf8)))
        #expect(try PostgresNull().encodeToText() == .sqlNull)
        #expect(try [UInt8]([0xde, 0xad]).encodeToText() == .bytes(Array("\\xdead".utf8)))
    }

    @Test func errorDescriptionsAreHumanReadable() {
        #expect(PostgresError.poolShutdown.description.contains("shut down"))
        #expect(PostgresError.timedOut.description.contains("timed out"))
        let serverError = PostgresServerError(severity: "ERROR", sqlState: "42P01", message: "relation does not exist", fields: [])
        #expect(PostgresError.server(serverError).description.contains("42P01"))
    }

    @Test func formatCodeRoundTrips() throws {
        #expect(PostgresFormat.text.code == 0)
        #expect(PostgresFormat.binary.code == 1)
        #expect(try PostgresFormat.from(code: 0) == .text)
        #expect(try PostgresFormat.from(code: 1) == .binary)
        #expect(throws: PostgresError.self) {
            try PostgresFormat.from(code: 7)
        }
    }
}
