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

// LowCardinality(Nullable(String)) is a common column shape (a dictionary-encoded
// nullable label). Reading it through the String accessor and a String? Codable
// field must work — a present value as its text, a NULL row as nil. This probes
// whether the client supports that shape against a real server.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct LowCardinalityNullableProbeTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct OptionalStringRow: Decodable, Sendable {

        let v: String?
    }

    @Test("string() reads a present LowCardinality(Nullable(String)) value", .timeLimit(.minutes(1)))
    func accessorPresent() async throws {
        let client = try await Self.makeClient()
        let result = try await client.query("SELECT CAST('hello' AS LowCardinality(Nullable(String))) AS v")
        #expect(try result.string("v", 0) == "hello")
        await client.close()
    }

    @Test("a String? field decodes a present LowCardinality(Nullable(String)) value", .timeLimit(.minutes(1)))
    func codablePresent() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST('hello' AS LowCardinality(Nullable(String))) AS v",
            as: OptionalStringRow.self
        )
        #expect(rows.count == 1)
        #expect(rows[0].v == "hello")
        await client.close()
    }

    @Test("a String? field decodes a NULL LowCardinality(Nullable(String)) row as nil", .timeLimit(.minutes(1)))
    func codableNull() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST(NULL AS LowCardinality(Nullable(String))) AS v",
            as: OptionalStringRow.self
        )
        #expect(rows.count == 1)
        #expect(rows[0].v == nil)
        await client.close()
    }
}
