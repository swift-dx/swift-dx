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

// Live-broker cover for Array(String) and Array(Int64) insert + select
// round-trips. Gated on CH_INTEGRATION_HOST.
@Suite(
    "DXClickHouse Array integration",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseArrayColumnIntegration {

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
            host: host, port: port,
            user: user, password: password, database: database
        )
    }

    struct StringArrayRow: Codable, Sendable, Equatable {
        let id: UInt64
        let tags: ClickHouseArray
    }

    @Test("Array(String) round-trips through insert and select")
    func arrayStringRoundTrip() async throws {
        let client = try await Self.makeClient()
        let table = "dx_arr_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (id UInt64, tags Array(String)) ENGINE = Memory")
        let rows = [
            StringArrayRow(id: 1, tags: ClickHouseArray.strings(["red", "green"])),
            StringArrayRow(id: 2, tags: ClickHouseArray.strings([])),
            StringArrayRow(id: 3, tags: ClickHouseArray.strings(["blue"])),
        ]
        _ = try await client.insert(into: table, rows: rows)
        let back = try await client.selectAll("SELECT id, tags FROM \(table) ORDER BY id ASC", as: StringArrayRow.self)
        #expect(back == rows)
        try await client.execute("DROP TABLE \(table)")
        await client.close()
    }
}
