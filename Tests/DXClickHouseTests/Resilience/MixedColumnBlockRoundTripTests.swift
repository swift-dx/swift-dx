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

// A realistic INSERT row mixes column families with different on-wire body
// shapes: a fixed-width scalar, a variable-length String, an Array (offsets +
// flattened elements), a Nullable(Decimal) (mask + width-truncated values), a
// LowCardinality (dictionary + indices), and a DateTime. The block writer
// emits each body back to back; the decoder walks them by offset. If any body
// writes a different byte count than the decoder reads, the NEXT column
// misaligns and the row is corrupted. This round-trips the whole block through
// the real wire encode/decode to prove the per-column boundaries line up.
@Suite("a mixed-type column block round-trips through the wire")
struct MixedColumnBlockRoundTripTests {

    private struct Event: Codable, Sendable, Equatable {
        let id: UInt64
        let name: String
        let tags: [String]
        let amount: ClickHouseDecimal?
        let status: ClickHouseLowCardinality
        let ts: Date
    }

    @Test("six different column-body shapes survive one block round-trip", .timeLimit(.minutes(1)))
    func mixedBlockRoundTrips() async throws {
        let rows = [
            Event(
                id: 1, name: "alpha", tags: ["a", "b"],
                amount: ClickHouseDecimal(unscaled: -150, precision: 10, scale: 2),
                status: ClickHouseLowCardinality("active"), ts: Date(timeIntervalSince1970: 1000)
            ),
            Event(
                id: 2, name: "", tags: [],
                amount: nil,
                status: ClickHouseLowCardinality("closed"), ts: Date(timeIntervalSince1970: 2000)
            ),
            Event(
                id: 3, name: "gamma", tags: ["x", "y", "z"],
                amount: ClickHouseDecimal(unscaled: 9999, precision: 10, scale: 2),
                status: ClickHouseLowCardinality("active"), ts: Date(timeIntervalSince1970: 3000)
            ),
        ]
        let columns = try ClickHouseRowEncoder().encode(rows)
        var packet = try ClickHouseBlockWriter.encodeDataPacket(columns: columns, revision: ClickHouseQueryBuilder.revision)
        packet[0] = 1
        var eos: [UInt8] = []; ClickHouseWire.writeUVarInt(5, into: &eos)

        let server = FakeClickHouseServer()
        server.run(serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision), script: [.drainRequest, .reply(packet + eos)])
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let decoded = try await client.selectAll("SELECT id, name, tags, amount, status, ts FROM t", as: Event.self)
        await client.close()

        #expect(decoded == rows)
    }
}
