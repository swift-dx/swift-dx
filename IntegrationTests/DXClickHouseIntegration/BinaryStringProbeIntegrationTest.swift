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

// ClickHouse String is an arbitrary byte sequence (the generic blob type),
// not necessarily UTF-8. This probes whether DXClickHouse can retrieve the
// exact bytes of a String column that holds binary data. The server-side
// hex() is the ground truth for what is stored.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct BinaryStringProbeIntegrationTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct BytesRow: Codable, Sendable { let b: [UInt8]; let h: String }

    @Test("a String column holding binary bytes is retrievable losslessly", .timeLimit(.minutes(1)))
    func binaryStringRoundTrips() async throws {
        let client = try await Self.makeClient()
        let table = "dx_binstr_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        try await client.execute("CREATE TABLE \(table) (b String) ENGINE = Memory")
        // 0xFF 0x00 0xFE 0x80 — invalid UTF-8 with an embedded NUL.
        try await client.execute("INSERT INTO \(table) VALUES (unhex('FF00FE80'))")
        let rows = try await client.selectAll("SELECT b, hex(b) AS h FROM \(table)", as: BytesRow.self)
        #expect(rows.count == 1)
        let decodedHex = rows[0].b.map { String(format: "%02X", $0) }.joined()
        #expect(decodedHex == rows[0].h, "binary String corrupted: decoded \(decodedHex) but server stored \(rows[0].h)")
    }
}
