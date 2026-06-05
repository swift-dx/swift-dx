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

// Map(LowCardinality(String), V) hoists the key dictionary's serialization
// version ahead of the map offsets, the same as Array(LowCardinality). The
// decoder resolves that dictionary and yields the native Swift map; this test
// pins both the decoded value and the decisive desync guard — a second query on
// the same connection must still read cleanly, proving the LowCardinality map
// was consumed to the exact byte rather than mis-framing the block and
// desyncing every later request.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct MapVariantProbeTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct StringMapRow: Decodable, Sendable {

        let m: [String: String]
    }

    private struct PlainRow: Decodable, Sendable, Equatable {

        let n: UInt32
    }

    @Test("Map(LowCardinality(String), String) decodes and keeps the connection in sync", .timeLimit(.minutes(1)))
    func mapWithLowCardinalityKeyStaysInSync() async throws {
        let client = try await Self.makeClient()

        let rows = try await client.selectAll(
            "SELECT CAST(map('a', 'x', 'b', 'y') AS Map(LowCardinality(String), String)) AS m",
            as: StringMapRow.self
        )
        #expect(rows.count == 1)
        #expect(rows[0].m == ["a": "x", "b": "y"])

        // The decisive desync check: a second query on the SAME connection. If
        // the Map(LowCardinality) read mis-framed the block, this read starts at
        // the wrong byte and fails or returns garbage.
        let after = try await client.selectAll("SELECT toUInt32(7) AS n", as: PlainRow.self)
        #expect(after == [PlainRow(n: 7)])

        await client.close()
    }
}
