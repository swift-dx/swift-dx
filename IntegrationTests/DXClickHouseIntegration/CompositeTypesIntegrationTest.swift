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

// The composite column types Array(Nullable(T)), Map(K, Nullable(V)), and
// Array(Array(T)) were originally validated only against fabricated wire
// payloads. This suite decodes them from a REAL ClickHouse server: the rows
// are inserted by the server's own client (authoritative wire bytes), then
// read back through DXClickHouse and compared. A wrong wire-format
// assumption that a self-consistent fake test cannot catch surfaces here.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct CompositeTypesIntegrationTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var user: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default" }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }
    private static var database: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "default" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: user, password: password, database: database)
    }

    struct ArrayNullableRow: Codable, Sendable, Equatable {
        let id: UInt32
        let vals: [Int64?]
        let names: [String?]
    }

    struct MapNullableRow: Codable, Sendable, Equatable {
        let id: UInt32
        let m: [String: String?]
    }

    struct NestedArrayRow: Codable, Sendable, Equatable {
        let id: UInt32
        let grid: [[Int64]]
    }

    @Test("Array(Nullable(T)) decodes from a real server", .timeLimit(.minutes(1)))
    func arrayNullable() async throws {
        let client = try await Self.makeClient()
        let table = "dx_anull_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        try await client.execute("CREATE TABLE \(table) (id UInt32, vals Array(Nullable(Int64)), names Array(Nullable(String))) ENGINE = Memory")
        try await client.execute("INSERT INTO \(table) VALUES (1, [1, NULL, 3], ['a', NULL]), (2, [], []), (3, [NULL], [NULL])")
        let back = try await client.selectAll("SELECT id, vals, names FROM \(table) ORDER BY id", as: ArrayNullableRow.self)
        #expect(back == [
            ArrayNullableRow(id: 1, vals: [1, nil, 3], names: ["a", nil]),
            ArrayNullableRow(id: 2, vals: [], names: []),
            ArrayNullableRow(id: 3, vals: [nil], names: [nil]),
        ])
        try await client.execute("DROP TABLE \(table)")
        await client.close()
    }

    @Test("Map(String, Nullable(String)) decodes from a real server", .timeLimit(.minutes(1)))
    func mapNullable() async throws {
        let client = try await Self.makeClient()
        let table = "dx_mapnull_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        try await client.execute("CREATE TABLE \(table) (id UInt32, m Map(String, Nullable(String))) ENGINE = Memory")
        try await client.execute("INSERT INTO \(table) VALUES (1, {'k1':'v1','k2':NULL}), (2, {})")
        let back = try await client.selectAll("SELECT id, m FROM \(table) ORDER BY id", as: MapNullableRow.self)
        #expect(back == [
            MapNullableRow(id: 1, m: ["k1": "v1", "k2": nil]),
            MapNullableRow(id: 2, m: [:]),
        ])
        try await client.execute("DROP TABLE \(table)")
        await client.close()
    }

    @Test("Array(Array(Int64)) decodes from a real server", .timeLimit(.minutes(1)))
    func nestedArray() async throws {
        let client = try await Self.makeClient()
        let table = "dx_nestarr_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        try await client.execute("CREATE TABLE \(table) (id UInt32, grid Array(Array(Int64))) ENGINE = Memory")
        try await client.execute("INSERT INTO \(table) VALUES (1, [[1,2],[3]]), (2, []), (3, [[],[4,5]])")
        let back = try await client.selectAll("SELECT id, grid FROM \(table) ORDER BY id", as: NestedArrayRow.self)
        #expect(back == [
            NestedArrayRow(id: 1, grid: [[1, 2], [3]]),
            NestedArrayRow(id: 2, grid: []),
            NestedArrayRow(id: 3, grid: [[], [4, 5]]),
        ])
        try await client.execute("DROP TABLE \(table)")
        await client.close()
    }
}
