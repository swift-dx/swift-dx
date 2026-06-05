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

// Server-side {name:Type} parameters exist so a value never has to be spliced
// into the SQL text — the server binds it as typed data, so a value carrying
// quotes, semicolons, or a `DROP TABLE` payload is returned verbatim rather than
// executed. This pins that injection-safety against a real server for a String
// binding, the case an interpolating client would be most exposed on.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct ParameterInjectionSafetyTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    @Test("a String parameter carrying injection characters binds as a literal value", .timeLimit(.minutes(1)))
    func stringParameterBindsAsLiteral() async throws {
        let client = try await Self.makeClient()
        let payload = "o'reilly\"; DROP TABLE users; -- \\ end"
        let parameters = ClickHouseQueryParameters([
            .string(name: "p", value: payload),
        ])
        let result = try await client.query("SELECT {p:String} AS v", parameters: parameters)
        #expect(result.rowCount == 1)
        #expect(try result.string("v", 0) == payload)
        await client.close()
    }

    @Test("String parameter edge cases round-trip through the typed factory", .timeLimit(.minutes(1)))
    func stringParameterEdgeCases() async throws {
        let client = try await Self.makeClient()
        let cases = [
            "",
            "'",
            "\\",
            "\\'",
            "plain",
            "café ☕ — unicode",
            "tab\tand spaces",
            "line1\nline2\r\nline3",
            "a\tb\nc\\d'e\"f",
            "'); DROP TABLE t; --",
            "\u{00}null-byte",
            "trailing backslash\\",
        ]
        for value in cases {
            let result = try await client.query(
                "SELECT {p:String} AS v",
                parameters: ClickHouseQueryParameters([.string(name: "p", value: value)])
            )
            #expect(try result.string("v", 0) == value, "round-trip failed for case \(value.debugDescription)")
        }
        await client.close()
    }
}
