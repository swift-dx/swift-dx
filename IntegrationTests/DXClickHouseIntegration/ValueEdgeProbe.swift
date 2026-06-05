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

// Value-correctness sweep: boundary integers, unsigned values above Int64.max,
// and signed minimums are the classic spots where a wrong cast silently corrupts
// data. Each must round-trip to the exact Swift value against a real server.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct ValueEdgeProbe {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct UInt64Row: Decodable, Sendable, Equatable {

        let v: UInt64
    }

    private struct Int64Row: Decodable, Sendable, Equatable {

        let v: Int64
    }

    private struct Int8Row: Decodable, Sendable, Equatable {

        let v: Int8
    }

    @Test("UInt64 above Int64.max round-trips exactly", .timeLimit(.minutes(1)))
    func uint64AboveInt64Max() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll("SELECT toUInt64(18446744073709551615) AS v", as: UInt64Row.self)
        #expect(rows == [UInt64Row(v: UInt64.max)])
        await client.close()
    }

    @Test("Int64 minimum round-trips exactly", .timeLimit(.minutes(1)))
    func int64Minimum() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll("SELECT toInt64(-9223372036854775808) AS v", as: Int64Row.self)
        #expect(rows == [Int64Row(v: Int64.min)])
        await client.close()
    }

    @Test("Int8 boundary values round-trip exactly", .timeLimit(.minutes(1)))
    func int8Boundaries() async throws {
        let client = try await Self.makeClient()
        let lo = try await client.selectAll("SELECT toInt8(-128) AS v", as: Int8Row.self)
        #expect(lo == [Int8Row(v: -128)])
        let hi = try await client.selectAll("SELECT toInt8(127) AS v", as: Int8Row.self)
        #expect(hi == [Int8Row(v: 127)])
        await client.close()
    }

    @Test("a column of mixed-sign Int64 values round-trips exactly", .timeLimit(.minutes(1)))
    func mixedSignInt64() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT arrayJoin([toInt64(-1), toInt64(0), toInt64(9223372036854775807), toInt64(-9223372036854775808)]) AS v",
            as: Int64Row.self
        )
        #expect(rows == [Int64Row(v: -1), Int64Row(v: 0), Int64Row(v: Int64.max), Int64Row(v: Int64.min)])
        await client.close()
    }
}
