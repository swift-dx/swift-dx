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

// LowCardinality(String) map keys (the recommended key type) combined with
// array values (multi-value attributes) — Map(LowCardinality(String),
// Array(V)) — is a real production shape. The key dictionary's version hoists
// ahead of the offsets while the array values keep their own per-entry offsets;
// the decoder must read both and yield [String: [V]] against a real server. A
// LowCardinality array element (Map(String, Array(LowCardinality(String))))
// hoists its version differently and is not yet supported; it must fail fast at
// a clean boundary and leave the pool usable, never mis-frame and hang.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct MapLowCardinalityArrayValueDecodeTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct StringArrayMapRow: Decodable, Sendable, Equatable {

        let v: [String: [String]]
    }

    private struct IntArrayMapRow: Decodable, Sendable, Equatable {

        let v: [String: [Int64]]
    }

    @Test("Map(LowCardinality(String), Array(String)) decodes into [String: [String]]", .timeLimit(.minutes(1)))
    func lowCardinalityKeyArrayValue() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST(map('tags', ['a', 'b'], 'flags', ['x']) AS Map(LowCardinality(String), Array(String))) AS v",
            as: StringArrayMapRow.self
        )
        #expect(rows == [StringArrayMapRow(v: ["tags": ["a", "b"], "flags": ["x"]])])
        await client.close()
    }

    private struct ProbeRow: Decodable, Sendable, Equatable {

        let x: Int64
    }

    @Test("Map(String, Array(LowCardinality(String))) fails fast and keeps the pool usable", .timeLimit(.minutes(1)))
    func lowCardinalityArrayElementFailsCleanly() async throws {
        let client = try await Self.makeClient()
        var rejected = false
        do {
            _ = try await client.selectAll(
                "SELECT CAST(map('tags', ['a', 'b', 'a']) AS Map(String, Array(LowCardinality(String)))) AS v",
                as: StringArrayMapRow.self
            )
        } catch {
            rejected = true
        }
        #expect(rejected)

        // A LowCardinality array element is rejected before any bytes are read,
        // so the block never mis-frames; a follow-up query proves the pool stayed
        // usable rather than desyncing or hanging on a half-consumed column.
        let after = try await client.selectAll("SELECT toInt64(7) AS x", as: ProbeRow.self)
        #expect(after == [ProbeRow(x: 7)])
        await client.close()
    }

    @Test("Map(LowCardinality(String), Array(Int64)) decodes into [String: [Int64]]", .timeLimit(.minutes(1)))
    func lowCardinalityKeyIntArrayValue() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST(map('lo', [toInt64(1), toInt64(2)], 'hi', [toInt64(9)]) AS Map(LowCardinality(String), Array(Int64))) AS v",
            as: IntArrayMapRow.self
        )
        #expect(rows == [IntArrayMapRow(v: ["lo": [1, 2], "hi": [9]])])
        await client.close()
    }

    @Test("Map(LowCardinality(String), Array(String)) decodes across multiple rows", .timeLimit(.minutes(1)))
    func lowCardinalityKeyArrayMultiRow() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST(map('k', [toString(number), toString(number + 1)]) AS Map(LowCardinality(String), Array(String))) AS v FROM numbers(3)",
            as: StringArrayMapRow.self
        )
        #expect(rows == [
            StringArrayMapRow(v: ["k": ["0", "1"]]),
            StringArrayMapRow(v: ["k": ["1", "2"]]),
            StringArrayMapRow(v: ["k": ["2", "3"]]),
        ])
        await client.close()
    }
}
