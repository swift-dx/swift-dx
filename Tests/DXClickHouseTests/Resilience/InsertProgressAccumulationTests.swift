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

// ClickHouse reports INSERT progress incrementally: each Progress packet
// carries the rows and bytes written since the previous packet. A
// multi-block INSERT therefore reports its written count across several
// packets, and the client must sum them to recover the true total.
// receiveEndOfStream feeds ClickHouseInsertSummary, so an accumulation
// bug here silently understates how many rows an INSERT actually wrote.
@Suite("INSERT end-of-stream sums incremental Progress write counters")
struct InsertProgressAccumulationTests {

    private static func progressPacket(writtenRows: UInt64, writtenBytes: UInt64) -> [UInt8] {
        var packet: [UInt8] = []
        ClickHouseWire.writeUVarInt(3, into: &packet) // packet type: Progress
        ClickHouseWire.writeUVarInt(0, into: &packet) // rows
        ClickHouseWire.writeUVarInt(0, into: &packet) // bytes
        ClickHouseWire.writeUVarInt(0, into: &packet) // totalRows
        ClickHouseWire.writeUVarInt(writtenRows, into: &packet)
        ClickHouseWire.writeUVarInt(writtenBytes, into: &packet)
        return packet
    }

    @Test("two incremental Progress packets are summed, not maxed", .timeLimit(.minutes(1)))
    func sumsIncrementalProgress() throws {
        var stream: [UInt8] = []
        stream += Self.progressPacket(writtenRows: 500, writtenBytes: 50)
        stream += Self.progressPacket(writtenRows: 700, writtenBytes: 70)
        ClickHouseWire.writeUVarInt(5, into: &stream) // packet type: EndOfStream

        let server = FakeClickHouseServer()
        // Revision 54_420 is the floor that carries write counters in
        // Progress packets.
        server.run(serverHello: FakeClickHouseServer.serverHello(revision: 54_420), afterHandshake: .sendThenClose(stream))

        let connection = try ClickHouseConnection(
            host: "127.0.0.1",
            port: server.port,
            reconnectionPolicy: .failFast
        )
        defer { connection.close() }

        let summary = try connection.receiveEndOfStream()
        #expect(summary.rows == 1200)
        #expect(summary.bytes == 120)
    }
}
