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

// A ClickHouse Nested column is stored on the wire as Array(Tuple(...)). A list
// of (name, count) records is the canonical production shape: event attributes,
// line items, key/value lists. With a scalar named Tuple decoding into a nested
// struct, the array form must decode into [Struct] against a real server, or
// fail cleanly without desyncing the connection.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct ArrayOfTupleDecodeTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct Pair: Decodable, Sendable, Equatable {

        let name: String
        let count: Int64
    }

    private struct NestedRow: Decodable, Sendable, Equatable {

        let v: [Pair]
    }

    @Test("a [Struct] field decodes an Array(Tuple(...)) column", .timeLimit(.minutes(1)))
    func arrayOfTuple() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST([('a', toInt64(1)), ('b', toInt64(2))] AS Array(Tuple(name String, count Int64))) AS v",
            as: NestedRow.self
        )
        #expect(rows == [NestedRow(v: [Pair(name: "a", count: 1), Pair(name: "b", count: 2)])])
        await client.close()
    }
}
