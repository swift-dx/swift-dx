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

// Array(LowCardinality(String)) is the canonical ClickHouse tag-array shape. It
// must read through the stringArray accessor and a [String] Codable field as the
// resolved tag values — the dictionary encoding being transparent — including
// repeated values (which share a dictionary entry) and the empty array. These
// pin that against a real server.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct ArrayLowCardinalityDecodeTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct TagsRow: Decodable, Sendable, Equatable {

        let tags: [String]
    }

    @Test("stringArray() reads an Array(LowCardinality(String)) with repeats", .timeLimit(.minutes(1)))
    func accessorReadsTags() async throws {
        let client = try await Self.makeClient()
        let result = try await client.query("SELECT CAST(['a', 'b', 'a', 'c'] AS Array(LowCardinality(String))) AS tags")
        #expect(try result.stringArray("tags", 0) == ["a", "b", "a", "c"])
        await client.close()
    }

    @Test("a [String] field decodes an Array(LowCardinality(String)) column", .timeLimit(.minutes(1)))
    func codableReadsTags() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST(['x', 'y', 'x'] AS Array(LowCardinality(String))) AS tags",
            as: TagsRow.self
        )
        #expect(rows == [TagsRow(tags: ["x", "y", "x"])])
        await client.close()
    }

    @Test("an all-empty Array(LowCardinality(String)) block decodes without hanging", .timeLimit(.minutes(1)))
    func allEmptyArray() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST([] AS Array(LowCardinality(String))) AS tags",
            as: TagsRow.self
        )
        #expect(rows == [TagsRow(tags: [])])
        await client.close()
    }

    @Test("Array(LowCardinality(String)) decodes across multiple rows including an empty one", .timeLimit(.minutes(1)))
    func multipleRows() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            """
            SELECT CAST(arr AS Array(LowCardinality(String))) AS tags
            FROM values('arr Array(String)', (['a', 'b']), ([]), (['c', 'a', 'c']))
            """,
            as: TagsRow.self
        )
        #expect(rows == [TagsRow(tags: ["a", "b"]), TagsRow(tags: []), TagsRow(tags: ["c", "a", "c"])])
        await client.close()
    }
}
