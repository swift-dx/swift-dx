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

// Live-broker cover for LowCardinality(String) insert + select round-trips.
// This is the test that actually validates the LowCardinality wire layout
// against a real ClickHouse server (the unit tests only prove encoder /
// decoder mutual consistency). Gated on CH_INTEGRATION_HOST.
@Suite(
    "DXClickHouse LowCardinality integration",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseLowCardinalityIntegration {

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

    struct Row: Codable, Sendable, Hashable {
        let tag: ClickHouseLowCardinality
    }

    @Test("LowCardinality(String) round-trips through insert and select")
    func lowCardinalityStringRoundTrip() async throws {
        let client = try await Self.makeClient()
        let table = "dx_lc_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (tag LowCardinality(String)) ENGINE = Memory")
        let rows = [
            Row(tag: ClickHouseLowCardinality("active")),
            Row(tag: ClickHouseLowCardinality("closed")),
            Row(tag: ClickHouseLowCardinality("active")),
        ]
        _ = try await client.insert(into: table, rows: rows)
        let back = try await client.selectAll("SELECT tag FROM \(table)", as: Row.self)
        #expect(Set(back) == Set(rows))
        #expect(back.count == rows.count)
        try await client.execute("DROP TABLE \(table)")
        await client.close()
    }
}
