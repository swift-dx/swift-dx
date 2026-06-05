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

// Array(LowCardinality(String)) is the canonical ClickHouse tag-array
// storage: an array whose elements are dictionary-encoded. On the wire the
// LowCardinality KeysSerializationVersion prefix is hoisted ahead of the
// array offsets, unlike a standalone LowCardinality column where the version
// is contiguous with the dictionary body. The reader must therefore read the
// version ahead of the offsets, then the flattened dictionary sub-column, and
// group the resolved values by the offsets. This test runs against a real
// ClickHouse server so the wire layout is the server's, not a fabricated
// assumption, and includes an empty tag row to cover the zero-length array.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct ArrayLowCardinalityIntegrationTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var user: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default" }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }
    private static var database: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "default" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: user, password: password, database: database)
    }

    struct TagsRow: Codable, Sendable, Equatable {
        let id: UInt32
        let tags: [String]
    }

    struct PlainRow: Codable, Sendable, Equatable {
        let n: UInt32
    }

    @Test("Array(LowCardinality(String)) round-trips and keeps the connection in sync", .timeLimit(.minutes(1)))
    func arrayLowCardinalityRoundTrip() async throws {
        let client = try await Self.makeClient()
        let table = "dx_lcarr_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (id UInt32, tags Array(LowCardinality(String))) ENGINE = Memory")
        try await client.execute("INSERT INTO \(table) VALUES (1, ['a','b']), (2, ['a']), (3, [])")

        let rows = try await client.selectAll("SELECT id, tags FROM \(table) ORDER BY id ASC", as: TagsRow.self)
        #expect(rows == [
            TagsRow(id: 1, tags: ["a", "b"]),
            TagsRow(id: 2, tags: ["a"]),
            TagsRow(id: 3, tags: []),
        ])

        // The decisive desync check: a second query on the SAME connection.
        // If the Array(LowCardinality) read mis-framed the block, this read
        // starts at the wrong byte and fails or returns garbage.
        let after = try await client.selectAll("SELECT toUInt32(7) AS n", as: PlainRow.self)
        #expect(after == [PlainRow(n: 7)])

        try await client.execute("DROP TABLE \(table)")
        await client.close()
    }
}
