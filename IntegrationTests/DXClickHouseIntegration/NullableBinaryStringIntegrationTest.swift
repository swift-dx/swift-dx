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

// Companion to the non-nullable binary String fix: a Nullable(String) column
// is also an arbitrary byte sequence per present row. A [UInt8]? field must
// read the exact bytes for present rows and nil for NULL rows. Verified
// against a real server, with hex() as the byte ground truth.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct NullableBinaryStringIntegrationTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct Row: Codable, Sendable { let b: [UInt8]? }

    @Test("Nullable(String) binary bytes and NULL round-trip through a [UInt8]? field", .timeLimit(.minutes(1)))
    func nullableBinaryRoundTrips() async throws {
        let client = try await Self.makeClient()
        let table = "dx_nbin_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        try await client.execute("CREATE TABLE \(table) (b Nullable(String)) ENGINE = Memory")
        try await client.execute("INSERT INTO \(table) VALUES (unhex('FF00FE80')), (NULL), (unhex('41'))")
        // rowNumberInAllBlocks keeps a stable order without depending on the
        // unordered value.
        let rows = try await client.selectAll("SELECT b FROM \(table) ORDER BY rowNumberInAllBlocks()", as: Row.self)
        #expect(rows.count == 3)
        #expect(rows[0].b == [0xFF, 0x00, 0xFE, 0x80])
        #expect(rows[1].b == nil)
        #expect(rows[2].b == [0x41])
        try await client.execute("DROP TABLE \(table)")
        await client.close()
    }
}
