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

// LowCardinality(String) is ClickHouse's recommended type for Map keys, so
// Map(LowCardinality(String), V) is the most common production map shape. Each
// LowCardinality side hoists its serialization version ahead of the offsets;
// the decoder must resolve the dictionary and yield the native Swift map
// against a real server, including LowCardinality on either or both sides, an
// empty map, and multiple rows sharing one dictionary, without desyncing.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct MapLowCardinalityKeyDecodeTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct StringMapRow: Decodable, Sendable, Equatable {

        let v: [String: String]
    }

    private struct IntMapRow: Decodable, Sendable, Equatable {

        let v: [String: Int64]
    }

    @Test("Map(LowCardinality(String), String) decodes into [String: String]", .timeLimit(.minutes(1)))
    func lowCardinalityKey() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST(map('region', 'eu', 'tier', 'gold') AS Map(LowCardinality(String), String)) AS v",
            as: StringMapRow.self
        )
        #expect(rows == [StringMapRow(v: ["region": "eu", "tier": "gold"])])
        await client.close()
    }

    @Test("Map(String, LowCardinality(String)) decodes into [String: String]", .timeLimit(.minutes(1)))
    func lowCardinalityValue() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST(map('region', 'eu', 'tier', 'gold') AS Map(String, LowCardinality(String))) AS v",
            as: StringMapRow.self
        )
        #expect(rows == [StringMapRow(v: ["region": "eu", "tier": "gold"])])
        await client.close()
    }

    @Test("Map(LowCardinality(String), LowCardinality(String)) decodes with both sides LC", .timeLimit(.minutes(1)))
    func lowCardinalityBothSides() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST(map('region', 'eu', 'tier', 'gold') AS Map(LowCardinality(String), LowCardinality(String))) AS v",
            as: StringMapRow.self
        )
        #expect(rows == [StringMapRow(v: ["region": "eu", "tier": "gold"])])
        await client.close()
    }

    @Test("Map(LowCardinality(String), Int64) decodes into [String: Int64]", .timeLimit(.minutes(1)))
    func lowCardinalityKeyNumericValue() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST(map('a', toInt64(1), 'b', toInt64(2)) AS Map(LowCardinality(String), Int64)) AS v",
            as: IntMapRow.self
        )
        #expect(rows == [IntMapRow(v: ["a": 1, "b": 2])])
        await client.close()
    }

    @Test("an empty Map(LowCardinality(String), String) decodes to an empty dictionary", .timeLimit(.minutes(1)))
    func emptyLowCardinalityMap() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST(map() AS Map(LowCardinality(String), String)) AS v",
            as: StringMapRow.self
        )
        #expect(rows == [StringMapRow(v: [:])])
        await client.close()
    }

    @Test("Map(LowCardinality(String), String) decodes across rows sharing a dictionary", .timeLimit(.minutes(1)))
    func lowCardinalityMultiRow() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST(map('env', if(number = 0, 'prod', 'stage')) AS Map(LowCardinality(String), LowCardinality(String))) AS v FROM numbers(3)",
            as: StringMapRow.self
        )
        #expect(rows == [
            StringMapRow(v: ["env": "prod"]),
            StringMapRow(v: ["env": "stage"]),
            StringMapRow(v: ["env": "stage"]),
        ])
        await client.close()
    }
}
