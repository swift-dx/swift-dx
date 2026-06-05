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

// The typed `{name:Type}` factories must produce a field dump the server can
// reconstruct as the declared scalar type. Without them a caller binds a number
// or boolean by hand-formatting the dump string, which is both a usability trap
// (the two-pass decode escaping is non-obvious) and the injection vector typed
// parameters exist to remove. These tests bind each factory against a real
// server and assert the value round-trips through `{name:Type}`, including the
// boundary values where a wrong format would surface.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct TypedParameterBindingTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    @Test("UInt64 parameter round-trips including the maximum", .timeLimit(.minutes(1)))
    func uint64RoundTrips() async throws {
        let client = try await Self.makeClient()
        for value in [UInt64(0), 1, 1729, UInt64.max] {
            let read = try await client.scalar(
                "SELECT {x:UInt64}",
                as: UInt64.self,
                parameters: ClickHouseQueryParameters([.uint64(name: "x", value: value)])
            )
            #expect(read == value)
        }
        await client.close()
    }

    @Test("Int64 parameter round-trips including the negative extremes", .timeLimit(.minutes(1)))
    func int64RoundTrips() async throws {
        let client = try await Self.makeClient()
        for value in [Int64(0), -1, 1729, Int64.min, Int64.max] {
            let read = try await client.scalar(
                "SELECT {x:Int64}",
                as: Int64.self,
                parameters: ClickHouseQueryParameters([.int64(name: "x", value: value)])
            )
            #expect(read == value)
        }
        await client.close()
    }

    @Test("Int parameter round-trips through Int64", .timeLimit(.minutes(1)))
    func intRoundTrips() async throws {
        let client = try await Self.makeClient()
        for value in [0, -42, 9999] {
            let read = try await client.scalar(
                "SELECT {x:Int64}",
                as: Int64.self,
                parameters: ClickHouseQueryParameters([.int(name: "x", value: value)])
            )
            #expect(read == Int64(value))
        }
        await client.close()
    }

    @Test("Float64 parameter round-trips an exact-binary value", .timeLimit(.minutes(1)))
    func doubleRoundTrips() async throws {
        let client = try await Self.makeClient()
        for value in [0.0, -2.5, 3.5, 1024.0] {
            let read = try await client.scalar(
                "SELECT {x:Float64}",
                as: Double.self,
                parameters: ClickHouseQueryParameters([.double(name: "x", value: value)])
            )
            #expect(read == value)
        }
        await client.close()
    }

    @Test("Bool parameter binds true and false", .timeLimit(.minutes(1)))
    func boolBinds() async throws {
        let client = try await Self.makeClient()
        for value in [true, false] {
            let read = try await client.scalar(
                "SELECT toUInt8({x:Bool})",
                as: UInt8.self,
                parameters: ClickHouseQueryParameters([.bool(name: "x", value: value)])
            )
            #expect(read == (value ? 1 : 0))
        }
        await client.close()
    }

    @Test("DateTime parameter binds an absolute instant as epoch seconds", .timeLimit(.minutes(1)))
    func dateTimeBindsEpoch() async throws {
        let client = try await Self.makeClient()
        for epoch in [Int64(100_000_000), 1_736_948_730, 2_000_000_000] {
            let value = Date(timeIntervalSince1970: TimeInterval(epoch))
            let read = try await client.scalar(
                "SELECT toInt64(toUnixTimestamp({t:DateTime}))",
                as: Int64.self,
                parameters: ClickHouseQueryParameters([.dateTime(name: "t", value: value)])
            )
            #expect(read == epoch)
        }
        await client.close()
    }

    @Test("DateTime parameter resolves to the same instant regardless of column timezone", .timeLimit(.minutes(1)))
    func dateTimeIsTimezoneIndependent() async throws {
        let client = try await Self.makeClient()
        let epoch: Int64 = 1_736_948_730
        let value = Date(timeIntervalSince1970: TimeInterval(epoch))
        let newYork = try await client.scalar(
            "SELECT toInt64(toUnixTimestamp({t:DateTime('America/New_York')}))",
            as: Int64.self,
            parameters: ClickHouseQueryParameters([.dateTime(name: "t", value: value)])
        )
        #expect(newYork == epoch)
        await client.close()
    }

    @Test("UUID parameter round-trips a fixed and a generated value", .timeLimit(.minutes(1)))
    func uuidRoundTrips() async throws {
        let client = try await Self.makeClient()
        let fixed = UUID(uuid: (0x61, 0xF0, 0xC4, 0x04, 0x5C, 0xB3, 0x11, 0xE7, 0x90, 0x7B, 0xA6, 0x00, 0x6A, 0xD3, 0xDB, 0xA0))
        for value in [fixed, UUID(), UUID()] {
            let result = try await client.query(
                "SELECT {x:UUID} AS v",
                parameters: ClickHouseQueryParameters([.uuid(name: "x", value: value)])
            )
            #expect(try result.uuid("v", 0) == value)
        }
        await client.close()
    }
}
