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

// A `SELECT ... WITH TOTALS` (or `extremes = 1`) query streams the result
// Data blocks, then a Totals block (packet type 7) or Extremes block
// (type 8), then EndOfStream. Those metadata blocks carry the same column
// shape as the data, so decoding them succeeds — but they are not result
// rows. They must be read off the wire to stay framed and then dropped,
// exactly like Log/ProfileEvents blocks, rather than yielded to the
// caller as a phantom extra row that silently inflates the result set.
@Suite("Totals and Extremes blocks are not surfaced as result rows")
struct TotalsBlockSkipTests {

    private struct Row: Decodable, Sendable, Equatable {
        let value: UInt8
    }

    // One UInt8 column ("value") with a single row carrying `value`,
    // framed as the given packet type (1 = Data, 7 = Totals, 8 = Extremes).
    private static func singleUInt8Block(packetType: UInt64, value: UInt8) -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(packetType, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("value", into: &bytes)
        ClickHouseWire.writeString("UInt8", into: &bytes)
        bytes.append(0)
        bytes.append(value)
        return bytes
    }

    private static func endOfStream() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(5, into: &bytes)
        return bytes
    }

    @Test("a WITH TOTALS result returns only the data rows, not the totals block", .timeLimit(.minutes(1)))
    func totalsBlockIsNotARow() async throws {
        var reply = Self.singleUInt8Block(packetType: 1, value: 10)
        reply.append(contentsOf: Self.singleUInt8Block(packetType: 7, value: 99))
        reply.append(contentsOf: Self.endOfStream())

        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(reply)]
        )
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let rows = try await client.selectAll("SELECT value FROM t WITH TOTALS", as: Row.self)
        await client.close()

        #expect(rows == [Row(value: 10)])
    }

    @Test("an extremes block is likewise dropped from the result rows", .timeLimit(.minutes(1)))
    func extremesBlockIsNotARow() async throws {
        var reply = Self.singleUInt8Block(packetType: 1, value: 7)
        reply.append(contentsOf: Self.singleUInt8Block(packetType: 8, value: 1))
        reply.append(contentsOf: Self.singleUInt8Block(packetType: 8, value: 255))
        reply.append(contentsOf: Self.endOfStream())

        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(reply)]
        )
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let rows = try await client.selectAll("SELECT value FROM t", as: Row.self)
        await client.close()

        #expect(rows == [Row(value: 7)])
    }
}
