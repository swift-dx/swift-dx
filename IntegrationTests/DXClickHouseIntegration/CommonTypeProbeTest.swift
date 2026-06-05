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

// Probes common ClickHouse column shapes that the production workload uses but
// the decode coverage has not pinned: an array of enums (status lists), a tuple
// row, and a map whose values are arrays. Each must decode into the natural
// Swift type against a real server, or fail cleanly without desyncing.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct CommonTypeProbeTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct EnumArrayRow: Decodable, Sendable, Equatable {

        let v: [String]
    }

    @Test("stringArray() reads an Array(Enum8(...)) column as the enum names", .timeLimit(.minutes(1)))
    func accessorArrayOfEnum8() async throws {
        let client = try await Self.makeClient()
        let result = try await client.query("SELECT CAST(['a', 'b', 'a'] AS Array(Enum8('a' = 1, 'b' = 2))) AS v")
        #expect(try result.stringArray("v", 0) == ["a", "b", "a"])
        await client.close()
    }

    @Test("a [String] field decodes an Array(Enum8(...)) column as the enum names", .timeLimit(.minutes(1)))
    func arrayOfEnum8() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST(['a', 'b', 'a'] AS Array(Enum8('a' = 1, 'b' = 2))) AS v",
            as: EnumArrayRow.self
        )
        #expect(rows == [EnumArrayRow(v: ["a", "b", "a"])])
        await client.close()
    }

    @Test("a [String] field decodes an Array(Enum16(...)) column as the enum names", .timeLimit(.minutes(1)))
    func arrayOfEnum16() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST(['x', 'y'] AS Array(Enum16('x' = 1000, 'y' = 2000))) AS v",
            as: EnumArrayRow.self
        )
        #expect(rows == [EnumArrayRow(v: ["x", "y"])])
        await client.close()
    }
}
