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

// Decoding a row through Codable is the primary read path, and modeling a
// FixedString(N) key or LowCardinality(FixedString(N)) code column as a plain
// `String` field is the natural shape. The columnar decoder must accept those
// columns for a `String` field — trimming the zero padding — rather than
// rejecting them and forcing the caller to model the field as a
// `ClickHouseFixedString`. These pin that against a real server.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct FixedStringCodableDecodeTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct StringRow: Decodable, Sendable {

        let v: String
    }

    private struct StringArrayRow: Decodable, Sendable {

        let v: [String]
    }

    private struct StringMapRow: Decodable, Sendable {

        let v: [String: String]
    }

    @Test("a String field decodes a padded FixedString column as trimmed text", .timeLimit(.minutes(1)))
    func stringFieldFromFixedString() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll("SELECT toFixedString('abc', 8) AS v", as: StringRow.self)
        #expect(rows.count == 1)
        #expect(rows[0].v == "abc")
        await client.close()
    }

    @Test("a String field decodes a full-width FixedString(44) identifier exactly", .timeLimit(.minutes(1)))
    func stringFieldFromFullWidthFixedString() async throws {
        let client = try await Self.makeClient()
        let identifier = "0123456789012345678901234567890123456789abcd"
        let rows = try await client.selectAll("SELECT toFixedString('\(identifier)', 44) AS v", as: StringRow.self)
        #expect(rows.count == 1)
        #expect(rows[0].v == identifier)
        await client.close()
    }

    @Test("a String field decodes a LowCardinality(FixedString(N)) column as trimmed text", .timeLimit(.minutes(1)))
    func stringFieldFromLowCardinalityFixedString() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST('hi' AS LowCardinality(FixedString(8))) AS v",
            as: StringRow.self
        )
        #expect(rows.count == 1)
        #expect(rows[0].v == "hi")
        await client.close()
    }

    @Test("a [String] field decodes an Array(FixedString(N)) column as trimmed text", .timeLimit(.minutes(1)))
    func stringArrayFieldFromFixedStringArray() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT [toFixedString('aa', 6), toFixedString('bbbbbb', 6), toFixedString('c', 6)] AS v",
            as: StringArrayRow.self
        )
        #expect(rows.count == 1)
        #expect(rows[0].v == ["aa", "bbbbbb", "c"])
        await client.close()
    }

    @Test("a [String:String] field decodes a Map(String, FixedString(N)) column as trimmed text", .timeLimit(.minutes(1)))
    func stringMapFieldFromMapFixedStringValue() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST(map('k1', 'aa', 'k2', 'bbbbbb') AS Map(String, FixedString(6))) AS v",
            as: StringMapRow.self
        )
        #expect(rows.count == 1)
        #expect(rows[0].v == ["k1": "aa", "k2": "bbbbbb"])
        await client.close()
    }
}
