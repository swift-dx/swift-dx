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

@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct EdgeCaseProbeIntegrationTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var user: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default" }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }
    private static var database: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "default" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: user, password: password, database: database)
    }

    private struct FloatRow: Codable, Sendable { let a: Double; let b: Double; let c: Double; let d: Float }

    @Test("float NaN/Inf/-Inf decode with the right bit patterns", .timeLimit(.minutes(1)))
    func floatSpecials() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll("SELECT nan AS a, inf AS b, -inf AS c, toFloat32(-inf) AS d", as: FloatRow.self)
        #expect(rows.count == 1)
        #expect(rows[0].a.isNaN)
        #expect(rows[0].b == .infinity)
        #expect(rows[0].c == -.infinity)
        #expect(rows[0].d == -.infinity)
        await client.close()
    }

    private struct NullableWideRow: Codable, Sendable {
        let a: ClickHouseDecimal?
        let b: ClickHouseDecimal?
        let c: ClickHouseInt128?
    }

    @Test("Nullable of wide types decodes NULL and present", .timeLimit(.minutes(1)))
    func nullableWide() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll("""
            SELECT CAST(NULL AS Nullable(Decimal(38,4))) AS a,
                   CAST(123.45 AS Nullable(Decimal(38,4))) AS b,
                   CAST(NULL AS Nullable(Int128)) AS c
            """, as: NullableWideRow.self)
        #expect(rows.count == 1)
        #expect(rows[0].a == nil)
        #expect(rows[0].b?.description == "123.4500")
        #expect(rows[0].c == nil)
        await client.close()
    }

    private struct NumberRow: Codable, Sendable { let number: UInt64 }

    @Test("a large multi-block result streams and accumulates every row", .timeLimit(.minutes(2)))
    func largeMultiBlock() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll("SELECT number FROM system.numbers LIMIT 500000", as: NumberRow.self)
        #expect(rows.count == 500000)
        #expect(rows.first?.number == 0)
        #expect(rows.last?.number == 499999)
        // Spot-check ordering integrity across block boundaries.
        var checksum: UInt64 = 0
        for row in rows { checksum = checksum &+ row.number }
        #expect(checksum == (499999 * 500000) / 2)
        await client.close()
    }
}
