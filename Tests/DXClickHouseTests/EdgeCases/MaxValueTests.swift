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

// Numeric boundary coverage. ClickHouse maps Int64.max etc. into the
// matching column types exactly; floating-point infinities and NaNs
// must survive the wire round-trip in both directions.
@Suite(
    "Numeric boundary round-trips: Int64/UInt64 limits and Float/Double specials",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseMaxValueTests {

    private static var host: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
    }
    private static var port: Int {
        Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
    }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port)
    }

    @Test("Int64.max round-trips through scalar()")
    func int64MaxRoundTrip() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar(
            "SELECT toInt64(9223372036854775807)",
            as: Int64.self
        )
        #expect(value == Int64.max)
    }

    @Test("Int64.min round-trips through scalar()")
    func int64MinRoundTrip() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar(
            "SELECT toInt64(-9223372036854775808)",
            as: Int64.self
        )
        #expect(value == Int64.min)
    }

    @Test("UInt64.max round-trips through scalar()")
    func uint64MaxRoundTrip() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar(
            "SELECT toUInt64(18446744073709551615)",
            as: UInt64.self
        )
        #expect(value == UInt64.max)
    }

    @Test("Int32.max and Int32.min round-trip")
    func int32BoundariesRoundTrip() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let high = try await client.scalar("SELECT toInt32(2147483647)", as: Int32.self)
        let low = try await client.scalar("SELECT toInt32(-2147483648)", as: Int32.self)
        #expect(high == Int32.max)
        #expect(low == Int32.min)
    }

    @Test("Float infinity round-trips and is recognised as infinite")
    func floatInfinityRoundTrip() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar(
            "SELECT toFloat32(inf)",
            as: Float.self
        )
        #expect(value.isInfinite)
        #expect(value > 0)
    }

    @Test("Float negative infinity round-trips")
    func floatNegativeInfinityRoundTrip() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar(
            "SELECT toFloat32(-inf)",
            as: Float.self
        )
        #expect(value.isInfinite)
        #expect(value < 0)
    }

    @Test("Double NaN round-trips as a NaN payload")
    func doubleNaNRoundTrip() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar(
            "SELECT toFloat64(nan)",
            as: Double.self
        )
        #expect(value.isNaN)
    }

    @Test("Double infinity round-trips")
    func doubleInfinityRoundTrip() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar(
            "SELECT toFloat64(inf)",
            as: Double.self
        )
        #expect(value.isInfinite)
    }

    @Test("UInt8.max round-trips through scalar()")
    func uint8MaxRoundTrip() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar("SELECT toUInt8(255)", as: UInt8.self)
        #expect(value == UInt8.max)
    }

    @Test("UInt16.max round-trips through scalar()")
    func uint16MaxRoundTrip() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar("SELECT toUInt16(65535)", as: UInt16.self)
        #expect(value == UInt16.max)
    }
}
