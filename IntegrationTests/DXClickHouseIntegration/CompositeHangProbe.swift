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

// Stability sweep: composite column shapes the typed decoder does not structurally
// support must FAIL FAST at a clean packet boundary and leave the pool usable —
// never mis-frame the block and hang the connection until the query timeout. Each
// probe reads an unsupported shape, then issues a second query on the same client;
// if the unsupported read mis-framed the block, the second read desyncs or the
// test runs for the full 30s query timeout instead of milliseconds.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct CompositeHangProbe {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct ProbeRow: Decodable, Sendable, Equatable {

        let x: Int64
    }

    private struct ThreeTuple: Decodable, Sendable, Equatable {

        let a: String
        let b: Int64
        let c: Double
    }

    private struct ThreeTupleArrayRow: Decodable, Sendable, Equatable {

        let v: [ThreeTuple]
    }

    @Test("Map(String, Tuple(String, Int64)) tuple value fails fast and keeps the pool usable", .timeLimit(.minutes(1)))
    func tupleValuedMap() async throws {
        let client = try await Self.makeClient()
        var rejected = false
        do {
            _ = try await client.selectAll(
                "SELECT CAST(map('k', ('a', toInt64(1))) AS Map(String, Tuple(String, Int64))) AS v",
                as: ThreeTupleArrayRow.self
            )
        } catch {
            rejected = true
        }
        #expect(rejected)
        let after = try await client.selectAll("SELECT toInt64(7) AS x", as: ProbeRow.self)
        #expect(after == [ProbeRow(x: 7)])
        await client.close()
    }

    @Test("Array(Map(String, String)) array-of-map fails fast and keeps the pool usable", .timeLimit(.minutes(1)))
    func arrayOfMap() async throws {
        let client = try await Self.makeClient()
        var rejected = false
        do {
            _ = try await client.selectAll(
                "SELECT [map('a', 'x'), map('b', 'y')] AS v",
                as: ThreeTupleArrayRow.self
            )
        } catch {
            rejected = true
        }
        #expect(rejected)
        let after = try await client.selectAll("SELECT toInt64(7) AS x", as: ProbeRow.self)
        #expect(after == [ProbeRow(x: 7)])
        await client.close()
    }
}
