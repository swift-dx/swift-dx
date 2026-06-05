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

// FixedString(N) and LowCardinality(FixedString(N)) are the identifier columns
// the production workload reads most (44-byte keys, low-cardinality codes). The
// `string(_:_:)` convenience must read them as text — trimming the zero padding a
// FixedString slot carries — rather than rejecting them and forcing callers onto
// the raw `bytes(_:_:)` path with a manual trim. These cases pin that against a
// real server.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct FixedStringStringAccessorTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    @Test("string() reads a padded FixedString column as trimmed text", .timeLimit(.minutes(1)))
    func fixedStringTrimmedText() async throws {
        let client = try await Self.makeClient()
        let result = try await client.query("SELECT toFixedString('abc', 8) AS v")
        #expect(try result.string("v", 0) == "abc")
        await client.close()
    }

    @Test("string() reads a full-width FixedString(44) identifier exactly", .timeLimit(.minutes(1)))
    func fixedStringFullWidth() async throws {
        let client = try await Self.makeClient()
        let identifier = "0123456789012345678901234567890123456789abcd"
        let result = try await client.query("SELECT toFixedString('\(identifier)', 44) AS v")
        #expect(try result.string("v", 0) == identifier)
        await client.close()
    }

    @Test("string() reads a LowCardinality(FixedString(N)) column as trimmed text", .timeLimit(.minutes(1)))
    func lowCardinalityFixedStringText() async throws {
        let client = try await Self.makeClient()
        let result = try await client.query("SELECT CAST('hi' AS LowCardinality(FixedString(8))) AS v")
        #expect(try result.string("v", 0) == "hi")
        await client.close()
    }

    @Test("stringArray() reads an Array(FixedString(N)) column as trimmed text", .timeLimit(.minutes(1)))
    func fixedStringArrayText() async throws {
        let client = try await Self.makeClient()
        let result = try await client.query(
            "SELECT [toFixedString('aa', 6), toFixedString('bbbbbb', 6), toFixedString('c', 6)] AS v"
        )
        #expect(try result.stringArray("v", 0) == ["aa", "bbbbbb", "c"])
        await client.close()
    }
}
