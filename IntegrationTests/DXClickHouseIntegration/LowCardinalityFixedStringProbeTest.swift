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

// LowCardinality(FixedString(N)) is a production code/identifier column shape
// (dictionary-encoded fixed-width values). It must read as trimmed text through
// the String accessor and a String field, and Array(LowCardinality(FixedString))
// as a [String]. These probe whether those shapes round-trip against a real
// server.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct LowCardinalityFixedStringProbeTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct StringRow: Decodable, Sendable {

        let v: String
    }

    private struct TagsRow: Decodable, Sendable, Equatable {

        let tags: [String]
    }

    @Test("string() reads a LowCardinality(FixedString(N)) column as trimmed text", .timeLimit(.minutes(1)))
    func accessorLowCardinalityFixedString() async throws {
        let client = try await Self.makeClient()
        let result = try await client.query("SELECT CAST('ab' AS LowCardinality(FixedString(8))) AS v")
        #expect(try result.string("v", 0) == "ab")
        await client.close()
    }

    @Test("a String field decodes a LowCardinality(FixedString(N)) column", .timeLimit(.minutes(1)))
    func codableLowCardinalityFixedString() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST('ab' AS LowCardinality(FixedString(8))) AS v",
            as: StringRow.self
        )
        #expect(rows.count == 1)
        #expect(rows[0].v == "ab")
        await client.close()
    }

    @Test("a [String] field decodes an Array(LowCardinality(FixedString(N)))", .timeLimit(.minutes(1)))
    func arrayLowCardinalityFixedString() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST(['aa', 'bb', 'aa'] AS Array(LowCardinality(FixedString(4)))) AS tags",
            as: TagsRow.self
        )
        #expect(rows == [TagsRow(tags: ["aa", "bb", "aa"])])
        await client.close()
    }
}
