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

// Modeling a FixedString(N) key column as a plain `String` field is the natural
// insert shape, mirroring the read side. The encoder must pad a `String` value
// into the fixed-width slot the target column declares rather than rejecting it
// or sending a mismatched String column. This pins the write path against a real
// server, round-tripping back through the String decode.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct StringFieldToFixedStringInsertTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct Row: Codable, Sendable, Equatable {

        let id: String
    }

    @Test("a String field inserts into a FixedString(44) column and round-trips", .timeLimit(.minutes(1)))
    func stringFieldInsertsIntoFixedString() async throws {
        let client = try await Self.makeClient()
        let table = "dx_str_to_fixed_test"
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (id FixedString(44)) ENGINE = Memory")
        let identifier = "0123456789012345678901234567890123456789abcd"
        _ = try await client.insert(into: table, rows: [Row(id: identifier)])
        let back = try await client.selectAll("SELECT id FROM \(table)", as: Row.self)
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        #expect(back == [Row(id: identifier)])
        await client.close()
    }

    @Test("a short String field is zero-padded into a wider FixedString column", .timeLimit(.minutes(1)))
    func shortStringFieldPads() async throws {
        let client = try await Self.makeClient()
        let table = "dx_str_to_fixed_pad_test"
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (id FixedString(8)) ENGINE = Memory")
        _ = try await client.insert(into: table, rows: [Row(id: "abc")])
        let back = try await client.selectAll("SELECT id FROM \(table)", as: Row.self)
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        #expect(back == [Row(id: "abc")])
        await client.close()
    }
}
