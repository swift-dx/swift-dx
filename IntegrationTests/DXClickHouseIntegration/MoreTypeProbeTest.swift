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

// Probes further common column shapes the decode coverage has not pinned:
// arrays of UUID / DateTime (id and timestamp lists) and a tuple decoded into a
// nested struct. Each must decode into the natural Swift type against a real
// server, or fail cleanly without desyncing.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct MoreTypeProbeTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct UUIDArrayRow: Decodable, Sendable, Equatable {

        let v: [UUID]
    }

    private struct DateArrayRow: Decodable, Sendable, Equatable {

        let v: [Date]
    }

    private struct Pair: Decodable, Sendable, Equatable {

        let name: String
        let count: Int64
    }

    private struct TupleRow: Decodable, Sendable, Equatable {

        let v: Pair
    }

    @Test("a [UUID] field decodes an Array(UUID) column", .timeLimit(.minutes(1)))
    func arrayOfUUID() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT [toUUID('61f0c404-5cb3-11e7-907b-a6006ad3dba0'), toUUID('00000000-0000-0000-0000-000000000001')] AS v",
            as: UUIDArrayRow.self
        )
        #expect(rows.count == 1)
        #expect(rows[0].v.count == 2)
        await client.close()
    }

    @Test("a [Date] field decodes an Array(DateTime) column", .timeLimit(.minutes(1)))
    func arrayOfDateTime() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT [toDateTime(1736948730), toDateTime(1700000000)] AS v",
            as: DateArrayRow.self
        )
        #expect(rows.count == 1)
        #expect(rows[0].v == [Date(timeIntervalSince1970: 1_736_948_730), Date(timeIntervalSince1970: 1_700_000_000)])
        await client.close()
    }

    @Test("a nested struct field decodes a named Tuple column", .timeLimit(.minutes(1)))
    func namedTuple() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST(('widget', toInt64(42)) AS Tuple(name String, count Int64)) AS v",
            as: TupleRow.self
        )
        #expect(rows == [TupleRow(v: Pair(name: "widget", count: 42))])
        await client.close()
    }
}
