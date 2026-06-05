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

// Map(String, Array(String)) is the canonical shape for multi-value attributes
// and tag sets (one key, many values). It must decode into the native Swift
// [String: [String]] against a real server, including an empty-value-array
// entry and a row whose map is empty, without desyncing the connection.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct MapArrayValueDecodeTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct MapArrayRow: Decodable, Sendable, Equatable {

        let v: [String: [String]]
    }

    @Test("Map(String, Array(String)) decodes into [String: [String]]", .timeLimit(.minutes(1)))
    func mapStringArrayString() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT map('x', ['a', 'b'], 'y', ['c'], 'z', []) AS v",
            as: MapArrayRow.self
        )
        #expect(rows == [MapArrayRow(v: ["x": ["a", "b"], "y": ["c"], "z": []])])
        await client.close()
    }

    @Test("Map(String, Array(String)) decodes across multiple rows", .timeLimit(.minutes(1)))
    func mapStringArrayMultiRow() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT map('k', [toString(number), toString(number + 1)]) AS v FROM numbers(3)",
            as: MapArrayRow.self
        )
        #expect(rows == [
            MapArrayRow(v: ["k": ["0", "1"]]),
            MapArrayRow(v: ["k": ["1", "2"]]),
            MapArrayRow(v: ["k": ["2", "3"]]),
        ])
        await client.close()
    }

    @Test("an empty Map(String, Array(String)) decodes to an empty dictionary", .timeLimit(.minutes(1)))
    func emptyMap() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST(map() AS Map(String, Array(String))) AS v",
            as: MapArrayRow.self
        )
        #expect(rows == [MapArrayRow(v: [:])])
        await client.close()
    }
}
