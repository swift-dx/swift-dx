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

// A LowCardinality column with more than 256 distinct values forces the
// encoder to widen its index from one byte to two (lowCardinalityWidthCode).
// Existing tests pin only the one-byte layout; the wide-index ENCODE path is
// exercised here by encoding 300 distinct values and reading them back through
// the real wire decode. A wrong index width would silently corrupt the values.
@Suite("a LowCardinality encode above 256 distinct values widens the index")
struct LowCardinalityWideIndexEncodeTests {

    private struct Row: Codable, Sendable, Equatable { let tag: ClickHouseLowCardinality }

    @Test("300 distinct LowCardinality values round-trip through the wire with a two-byte index", .timeLimit(.minutes(1)))
    func wideIndexEncodeRoundTrips() async throws {
        let rows = (0..<300).map { Row(tag: ClickHouseLowCardinality("v\($0)")) }
        let columns = try ClickHouseRowEncoder().encode(rows)
        #expect(columns[0].column.typeName == "LowCardinality(String)")

        // Serialize the block, then re-tag the leading INSERT Data packet (2)
        // as a server SELECT Data packet (1) so it flows through the decoder.
        var packet = try ClickHouseBlockWriter.encodeDataPacket(columns: columns, revision: ClickHouseQueryBuilder.revision)
        #expect(packet.first == 2)
        packet[0] = 1
        var eos: [UInt8] = []
        ClickHouseWire.writeUVarInt(5, into: &eos)
        let reply = packet + eos

        let server = FakeClickHouseServer()
        server.run(serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision), script: [.drainRequest, .reply(reply)])
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let decoded = try await client.selectAll("SELECT tag FROM t", as: Row.self)
        await client.close()

        #expect(decoded == rows)
    }
}
