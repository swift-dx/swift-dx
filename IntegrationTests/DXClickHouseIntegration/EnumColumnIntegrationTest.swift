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

// Live-broker cover for Enum8 insert + select round-trips. Gated on
// CH_INTEGRATION_HOST so it only runs when a live ClickHouse is wired.
@Suite(
    "DXClickHouse Enum integration",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseEnumColumnIntegration {

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

    static let status: [ClickHouseEnumPair] = [
        ClickHouseEnumPair(name: "active", value: 1),
        ClickHouseEnumPair(name: "closed", value: 2),
    ]

    struct Row: Codable, Sendable, Equatable {
        let status: ClickHouseEnum8
    }

    @Test("Enum8 round-trips through insert and select")
    func enum8RoundTrip() async throws {
        let client = try await Self.makeClient()
        let table = "dx_enum_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (status Enum8('active' = 1, 'closed' = 2)) ENGINE = Memory")
        let rows = [
            Row(status: ClickHouseEnum8(value: 1, mapping: Self.status)),
            Row(status: ClickHouseEnum8(value: 2, mapping: Self.status)),
        ]
        _ = try await client.insert(into: table, rows: rows)
        let back = try await client.selectAll("SELECT status FROM \(table) ORDER BY status ASC", as: Row.self)
        #expect(back == rows)
        try await client.execute("DROP TABLE \(table)")
        await client.close()
    }
}
