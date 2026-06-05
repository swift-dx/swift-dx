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

// Nullable(FixedString(N)) is the natural column type for an optional fixed-width
// key or code. Modeling it as a `String?` field must decode a present value as
// trimmed text and a NULL row as nil, the same FixedString interpretation the
// non-optional path applies. These pin that against a real server.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct NullableFixedStringDecodeTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct OptionalStringRow: Decodable, Sendable {

        let v: String?
    }

    @Test("a String? field decodes a present Nullable(FixedString) value as trimmed text", .timeLimit(.minutes(1)))
    func presentValue() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST(toFixedString('abc', 8) AS Nullable(FixedString(8))) AS v",
            as: OptionalStringRow.self
        )
        #expect(rows.count == 1)
        #expect(rows[0].v == "abc")
        await client.close()
    }

    @Test("a String? field decodes a NULL Nullable(FixedString) row as nil", .timeLimit(.minutes(1)))
    func nullRow() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST(NULL AS Nullable(FixedString(8))) AS v",
            as: OptionalStringRow.self
        )
        #expect(rows.count == 1)
        #expect(rows[0].v == nil)
        await client.close()
    }
}
