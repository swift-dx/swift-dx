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

@Suite(
    "ClickHouseClient scalar happy paths across primitive types",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseClientScalarTests {

    private static var host: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
    }

    private static var port: Int {
        Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
    }

    private static var user: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default"
    }

    private static var password: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? ""
    }

    private static var database: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "default"
    }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(
            host: host,
            port: port,
            user: user,
            password: password,
            database: database
        )
    }

    // ---- Signed integers ----

    @Test("scalar Int8 decodes a single-cell SELECT toInt8(-5)")
    func scalarInt8() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar("SELECT toInt8(-5)", as: Int8.self)
        #expect(value == -5)
    }

    @Test("scalar Int16 decodes toInt16(-32000)")
    func scalarInt16() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar("SELECT toInt16(-32000)", as: Int16.self)
        #expect(value == -32000)
    }

    @Test("scalar Int32 decodes toInt32(-2000000000)")
    func scalarInt32() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar("SELECT toInt32(-2000000000)", as: Int32.self)
        #expect(value == -2_000_000_000)
    }

    @Test("scalar Int64 decodes toInt64(-9000000000000000000)")
    func scalarInt64() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar("SELECT toInt64(-9000000000000000000)", as: Int64.self)
        #expect(value == -9_000_000_000_000_000_000)
    }

    // ---- Unsigned integers ----

    @Test("scalar UInt8 decodes toUInt8(200)")
    func scalarUInt8() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar("SELECT toUInt8(200)", as: UInt8.self)
        #expect(value == 200)
    }

    @Test("scalar UInt16 decodes toUInt16(60000)")
    func scalarUInt16() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar("SELECT toUInt16(60000)", as: UInt16.self)
        #expect(value == 60_000)
    }

    @Test("scalar UInt32 decodes toUInt32(4000000000)")
    func scalarUInt32() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar("SELECT toUInt32(4000000000)", as: UInt32.self)
        #expect(value == 4_000_000_000)
    }

    @Test("scalar UInt64 decodes toUInt64(18000000000000000000)")
    func scalarUInt64() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar("SELECT toUInt64(18000000000000000000)", as: UInt64.self)
        #expect(value == 18_000_000_000_000_000_000)
    }

    // ---- Floats ----

    @Test("scalar Float decodes toFloat32(3.5)")
    func scalarFloat32() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar("SELECT toFloat32(3.5)", as: Float.self)
        #expect(value == 3.5)
    }

    @Test("scalar Double decodes toFloat64(2.71828)")
    func scalarFloat64() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar("SELECT toFloat64(2.71828)", as: Double.self)
        #expect(value == 2.71828)
    }

    // ---- Bool / String / UUID ----

    @Test("scalar Bool decodes toBool(true)")
    func scalarBool() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar("SELECT toBool(1)", as: Bool.self)
        #expect(value == true)
    }

    @Test("scalar String decodes a UTF-8 literal")
    func scalarString() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar("SELECT 'hello world'", as: String.self)
        #expect(value == "hello world")
    }

    @Test("scalar UUID decodes a literal toUUID")
    func scalarUUID() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar(
            "SELECT toUUID('11111111-2222-3333-4444-555555555555')",
            as: UUID.self
        )
        #expect(value.uuidString.lowercased() == "11111111-2222-3333-4444-555555555555")
    }

    @Test("scalar Date decodes toDateTime")
    func scalarDate() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        // ClickHouse computes the Unix epoch for the literal server-side
        // via toUnixTimestamp; the client just round-trips that same
        // value via toDateTime → Date. Comparing both pins the contract
        // without hardcoding a hand-computed epoch.
        let expected = try await client.scalar(
            "SELECT toUInt64(toUnixTimestamp(toDateTime('2026-05-30 12:00:00', 'UTC')))",
            as: UInt64.self
        )
        let value = try await client.scalar(
            "SELECT toDateTime('2026-05-30 12:00:00', 'UTC')",
            as: Date.self
        )
        #expect(UInt64(value.timeIntervalSince1970) == expected)
    }

    // ---- Bytes overload ----

    @Test("scalar([UInt8]) decodes via the bytes overload")
    func scalarFromBytes() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar(
            Array("SELECT toUInt64(42)".utf8),
            as: UInt64.self
        )
        #expect(value == 42)
    }

    // ---- Timeout override ----

    @Test("scalar accepts an explicit timeout override")
    func scalarWithTimeout() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar("SELECT toUInt64(7)", as: UInt64.self, timeout: .seconds(5))
        #expect(value == 7)
    }

    @Test("scalar with timeout .zero runs without a local deadline")
    func scalarWithZeroTimeout() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar("SELECT toUInt64(11)", as: UInt64.self, timeout: .zero)
        #expect(value == 11)
    }
}
