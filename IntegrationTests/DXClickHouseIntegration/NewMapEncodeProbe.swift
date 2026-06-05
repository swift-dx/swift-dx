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

// Round-trip encode probe for the map shapes whose decode landed recently:
// array-valued maps and LowCardinality-keyed maps. A consumer that can read a
// column expects to insert it too. Each row is inserted through the Codable
// encode path and read back through the server's trusted toString(); a wrong or
// missing encode either throws or makes the read-back disagree. An unsupported
// shape must fail at a clean boundary, never corrupt the stored bytes.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct NewMapEncodeProbe {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct StringRow: Codable, Sendable, Equatable { let s: String }

    private static func uniqueTable(_ prefix: String) -> String {
        "\(prefix)_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
    }

    @Test("Map(String, Array(String)) inserts and reads back byte-correct", .timeLimit(.minutes(1)))
    func arrayValuedMapEncode() async throws {
        struct Row: Codable, Sendable { let m: [String: [String]] }
        let client = try await Self.makeClient()
        let table = Self.uniqueTable("dx_encmaparr")
        try await client.execute("CREATE TABLE \(table) (m Map(String, Array(String))) ENGINE = Memory")
        _ = try await client.insert(into: table, rows: [Row(m: ["x": ["a", "b"]])])
        let back = try await client.selectAll("SELECT toString(m) AS s FROM \(table)", as: StringRow.self)
        #expect(back == [StringRow(s: "{'x':['a','b']}")])
        try await client.execute("DROP TABLE \(table)")
        await client.close()
    }

    @Test("Map(String, Array(Int64)) inserts and reads back byte-correct", .timeLimit(.minutes(1)))
    func intArrayValuedMapEncode() async throws {
        struct Row: Codable, Sendable { let m: [String: [Int64]] }
        let client = try await Self.makeClient()
        let table = Self.uniqueTable("dx_encmapintarr")
        try await client.execute("CREATE TABLE \(table) (m Map(String, Array(Int64))) ENGINE = Memory")
        _ = try await client.insert(into: table, rows: [Row(m: ["lo": [1, 2]])])
        let back = try await client.selectAll("SELECT toString(m) AS s FROM \(table)", as: StringRow.self)
        #expect(back == [StringRow(s: "{'lo':[1,2]}")])
        try await client.execute("DROP TABLE \(table)")
        await client.close()
    }

    @Test("Map(LowCardinality(String), String) inserts and reads back byte-correct", .timeLimit(.minutes(1)))
    func lowCardinalityKeyMapEncode() async throws {
        struct Row: Codable, Sendable { let m: [String: String] }
        let client = try await Self.makeClient()
        let table = Self.uniqueTable("dx_encmaplc")
        try await client.execute("CREATE TABLE \(table) (m Map(LowCardinality(String), String)) ENGINE = Memory")
        _ = try await client.insert(into: table, rows: [Row(m: ["region": "eu"])])
        let back = try await client.selectAll("SELECT toString(m) AS s FROM \(table)", as: StringRow.self)
        #expect(back == [StringRow(s: "{'region':'eu'}")])
        try await client.execute("DROP TABLE \(table)")
        await client.close()
    }

    @Test("array-valued map round-trips through DXClickHouse decode", .timeLimit(.minutes(1)))
    func arrayValuedMapDXRoundTrip() async throws {
        struct Row: Codable, Sendable, Equatable { let m: [String: [String]] }
        let client = try await Self.makeClient()
        let table = Self.uniqueTable("dx_encmaprt")
        try await client.execute("CREATE TABLE \(table) (m Map(String, Array(String))) ENGINE = Memory")
        let original = Row(m: ["tags": ["a", "b"], "flags": ["x"]])
        _ = try await client.insert(into: table, rows: [original])
        let back = try await client.selectAll("SELECT m FROM \(table)", as: Row.self)
        #expect(back == [original])
        try await client.execute("DROP TABLE \(table)")
        await client.close()
    }
}
