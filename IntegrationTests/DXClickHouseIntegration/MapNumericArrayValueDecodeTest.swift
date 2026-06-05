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

// Numeric array-valued maps are the shape for per-key metric series and counts
// (Map(String, Array(Int64)) / Array(Float64)). Each must decode into the
// native Swift [String: [V]] against a real server, including an empty value
// array, without desyncing the connection.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct MapNumericArrayValueDecodeTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct IntArrayMapRow: Decodable, Sendable, Equatable {

        let v: [String: [Int64]]
    }

    private struct DoubleArrayMapRow: Decodable, Sendable, Equatable {

        let v: [String: [Double]]
    }

    @Test("Map(String, Array(Int64)) decodes into [String: [Int64]]", .timeLimit(.minutes(1)))
    func intArrayValueMap() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT map('lo', [toInt64(1), toInt64(2)], 'hi', [toInt64(9)], 'none', CAST([] AS Array(Int64))) AS v",
            as: IntArrayMapRow.self
        )
        #expect(rows == [IntArrayMapRow(v: ["lo": [1, 2], "hi": [9], "none": []])])
        await client.close()
    }

    @Test("Map(String, Array(Float64)) decodes into [String: [Double]]", .timeLimit(.minutes(1)))
    func doubleArrayValueMap() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT map('p50', [0.5, 1.5], 'p99', [9.5]) AS v",
            as: DoubleArrayMapRow.self
        )
        #expect(rows == [DoubleArrayMapRow(v: ["p50": [0.5, 1.5], "p99": [9.5]])])
        await client.close()
    }

    @Test("Map(String, Array(Int64)) decodes across multiple rows", .timeLimit(.minutes(1)))
    func intArrayMultiRow() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT map('n', [toInt64(number), toInt64(number * 2)]) AS v FROM numbers(3)",
            as: IntArrayMapRow.self
        )
        #expect(rows == [
            IntArrayMapRow(v: ["n": [0, 0]]),
            IntArrayMapRow(v: ["n": [1, 2]]),
            IntArrayMapRow(v: ["n": [2, 4]]),
        ])
        await client.close()
    }
}
