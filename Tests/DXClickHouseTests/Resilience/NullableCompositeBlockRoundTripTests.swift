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

@testable import DXClickHouse
import Foundation
import Testing

// The two nullable-composite column types — Array(Nullable(T)) and
// Map(K, Nullable(V)) — each carry an offsets section, a null mask, and a
// flattened value column. Placed adjacent in one block they must keep their
// per-column byte boundaries exact: a length mistake in either body would
// misalign the next column. This round-trips a row with both, plus core
// columns, through the real wire encode/decode.
@Suite("a block mixing Array(Nullable) and Map(Nullable value) round-trips")
struct NullableCompositeBlockRoundTripTests {

    private struct Row: Codable, Sendable, Equatable {
        let id: UInt64
        let tags: [String?]
        let attrs: [String: String?]
        let name: String
    }

    @Test("Array(Nullable(String)) and Map(String, Nullable(String)) compose in one block", .timeLimit(.minutes(1)))
    func nullableCompositesCompose() async throws {
        let rows = [
            Row(id: 1, tags: ["a", nil, "c"], attrs: ["x": "1", "y": nil], name: "alpha"),
            Row(id: 2, tags: [], attrs: [:], name: ""),
            Row(id: 3, tags: [nil], attrs: ["z": nil, "w": "9"], name: "gamma"),
        ]
        let columns = try ClickHouseRowEncoder().encode(rows)
        var packet = try ClickHouseBlockWriter.encodeDataPacket(columns: columns, revision: ClickHouseQueryBuilder.revision)
        packet[0] = 1
        var eos: [UInt8] = []; ClickHouseWire.writeUVarInt(5, into: &eos)

        let server = FakeClickHouseServer()
        server.run(serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision), script: [.drainRequest, .reply(packet + eos)])
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let decoded = try await client.selectAll("SELECT id, tags, attrs, name FROM t", as: Row.self)
        await client.close()

        #expect(decoded == rows)
    }
}
