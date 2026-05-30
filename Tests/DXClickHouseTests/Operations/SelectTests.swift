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
    "ClickHouseClient select happy paths across primitive types",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseClientSelectTests {

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

    struct Int8Row: Decodable, Sendable, Equatable { let v: Int8 }
    struct Int16Row: Decodable, Sendable, Equatable { let v: Int16 }
    struct Int32Row: Decodable, Sendable, Equatable { let v: Int32 }
    struct Int64Row: Decodable, Sendable, Equatable { let v: Int64 }
    struct UInt8Row: Decodable, Sendable, Equatable { let v: UInt8 }
    struct UInt16Row: Decodable, Sendable, Equatable { let v: UInt16 }
    struct UInt32Row: Decodable, Sendable, Equatable { let v: UInt32 }
    struct UInt64Row: Decodable, Sendable, Equatable { let v: UInt64 }
    struct Float32Row: Decodable, Sendable, Equatable { let v: Float }
    struct Float64Row: Decodable, Sendable, Equatable { let v: Double }
    struct BoolRow: Decodable, Sendable, Equatable { let v: Bool }
    struct StringRow: Decodable, Sendable, Equatable { let v: String }
    struct UUIDRow: Decodable, Sendable, Equatable { let v: UUID }
    struct DateRow: Decodable, Sendable, Equatable { let v: Date }

    @Test("select streams N Int8 rows")
    func selectInt8Stream() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        var rows: [Int8Row] = []
        for try await row in client.select("SELECT toInt8(number) AS v FROM numbers(3)", as: Int8Row.self) {
            rows.append(row)
        }
        #expect(rows == [Int8Row(v: 0), Int8Row(v: 1), Int8Row(v: 2)])
    }

    @Test("selectAll materializes N Int16 rows into an Array")
    func selectInt16Materialized() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let rows = try await client.selectAll(
            "SELECT toInt16(number) AS v FROM numbers(3)",
            as: Int16Row.self
        )
        #expect(rows == [Int16Row(v: 0), Int16Row(v: 1), Int16Row(v: 2)])
    }

    @Test("selectAll Int32 round-trips ascending values")
    func selectInt32() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let rows = try await client.selectAll(
            "SELECT toInt32(number) AS v FROM numbers(4)",
            as: Int32Row.self
        )
        #expect(rows.map(\.v) == [0, 1, 2, 3])
    }

    @Test("selectAll Int64 round-trips ascending values")
    func selectInt64() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let rows = try await client.selectAll(
            "SELECT toInt64(number) AS v FROM numbers(4)",
            as: Int64Row.self
        )
        #expect(rows.map(\.v) == [0, 1, 2, 3])
    }

    @Test("selectAll UInt8 returns the requested values")
    func selectUInt8() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let rows = try await client.selectAll(
            "SELECT toUInt8(number) AS v FROM numbers(3)",
            as: UInt8Row.self
        )
        #expect(rows.map(\.v) == [0, 1, 2])
    }

    @Test("selectAll UInt16 returns the requested values")
    func selectUInt16() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let rows = try await client.selectAll(
            "SELECT toUInt16(number) AS v FROM numbers(3)",
            as: UInt16Row.self
        )
        #expect(rows.map(\.v) == [0, 1, 2])
    }

    @Test("selectAll UInt32 returns the requested values")
    func selectUInt32() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let rows = try await client.selectAll(
            "SELECT toUInt32(number) AS v FROM numbers(3)",
            as: UInt32Row.self
        )
        #expect(rows.map(\.v) == [0, 1, 2])
    }

    @Test("selectAll UInt64 returns the requested values")
    func selectUInt64() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let rows = try await client.selectAll(
            "SELECT toUInt64(number) AS v FROM numbers(3)",
            as: UInt64Row.self
        )
        #expect(rows.map(\.v) == [0, 1, 2])
    }

    @Test("selectAll Float32 round-trips simple values")
    func selectFloat32() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let rows = try await client.selectAll(
            "SELECT toFloat32(number) AS v FROM numbers(3)",
            as: Float32Row.self
        )
        #expect(rows.map(\.v) == [0.0, 1.0, 2.0])
    }

    @Test("selectAll Float64 round-trips simple values")
    func selectFloat64() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let rows = try await client.selectAll(
            "SELECT toFloat64(number) AS v FROM numbers(3)",
            as: Float64Row.self
        )
        #expect(rows.map(\.v) == [0.0, 1.0, 2.0])
    }

    @Test("selectAll Bool round-trips via toBool")
    func selectBool() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let rows = try await client.selectAll(
            "SELECT toBool(number) AS v FROM numbers(2)",
            as: BoolRow.self
        )
        #expect(rows == [BoolRow(v: false), BoolRow(v: true)])
    }

    @Test("selectAll String round-trips literal values")
    func selectString() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let rows = try await client.selectAll(
            "SELECT toString(number) AS v FROM numbers(3)",
            as: StringRow.self
        )
        #expect(rows == [StringRow(v: "0"), StringRow(v: "1"), StringRow(v: "2")])
    }

    @Test("selectAll UUID round-trips literal UUIDs")
    func selectUUID() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let rows = try await client.selectAll(
            "SELECT toUUID('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee') AS v",
            as: UUIDRow.self
        )
        #expect(rows.count == 1)
        #expect(rows[0].v.uuidString.lowercased() == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    }

    @Test("selectAll Date round-trips a single DateTime value")
    func selectDate() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let rows = try await client.selectAll(
            "SELECT toDateTime('2026-01-01 00:00:00', 'UTC') AS v",
            as: DateRow.self
        )
        #expect(rows.count == 1)
    }

    @Test("select stream consumes 100 rows via AsyncThrowingStream")
    func selectStreamLargeCount() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        var count = 0
        for try await _ in client.select(
            "SELECT toUInt64(number) AS v FROM numbers(100)",
            as: UInt64Row.self
        ) {
            count += 1
        }
        #expect(count == 100)
    }

    @Test("select with explicit settings runs and returns rows")
    func selectWithSettings() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let settings = ClickHouseQuerySettings([
            ClickHouseQuerySetting(name: "max_threads", value: "1"),
        ])
        let rows = try await client.selectAll(
            "SELECT toUInt64(number) AS v FROM numbers(5)",
            as: UInt64Row.self,
            settings: settings
        )
        #expect(rows.count == 5)
    }

    @Test("select with parameters substitutes a String binding")
    func selectWithParameters() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let parameters = ClickHouseQueryParameters([
            ClickHouseQueryParameter(name: "label", value: "'hello'"),
        ])
        let rows = try await client.selectAll(
            "SELECT {label:String} AS v",
            as: StringRow.self,
            parameters: parameters
        )
        #expect(rows == [StringRow(v: "hello")])
    }

    @Test("select returns an empty array for a zero-row query")
    func selectEmpty() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let rows = try await client.selectAll(
            "SELECT toUInt64(number) AS v FROM numbers(0)",
            as: UInt64Row.self
        )
        #expect(rows.isEmpty)
    }
}
