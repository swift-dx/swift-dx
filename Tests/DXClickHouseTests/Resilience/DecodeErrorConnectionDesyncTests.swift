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

// A SELECT whose rows fail to decode into the caller's type must not
// leave the connection desynchronized. The result blocks are fully read
// off the socket inside readBlockPacket before the Codable decode runs,
// so a decode failure that aborts the receive loop early leaves the
// trailing EndOfStream packet (and any later packets) unread on the
// wire. The next operation then reads those stale bytes: a ping would
// see the leftover EndOfStream (packet type 5) instead of its Pong and
// fail with "unexpected packet type 5". The receive loop must instead
// drain to EndOfStream even when a block fails to decode, surfacing the
// decode error only after the connection is back at a clean boundary.
@Suite("A decode failure leaves the connection usable for the next request")
struct DecodeErrorConnectionDesyncTests {

    private struct IntRow: Decodable, Sendable {

        let value: Int
    }

    // Data packet carrying one String column ("value" = "x"), followed by
    // EndOfStream. Decoding the String row into IntRow.value fails, which
    // is exactly the mid-stream decode error under test.
    private static func stringBlockThenEndOfStream() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("value", into: &bytes)
        ClickHouseWire.writeString("String", into: &bytes)
        bytes.append(0)
        ClickHouseWire.writeString("x", into: &bytes)
        ClickHouseWire.writeUVarInt(5, into: &bytes)
        return bytes
    }

    @Test("a ping after a failed-decode SELECT gets its Pong, not a stale EndOfStream", .timeLimit(.minutes(1)))
    func pingSucceedsAfterDecodeFailure() async throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [
                .drainRequest,
                .reply(Self.stringBlockThenEndOfStream()),
                .drainRequest,
                .reply([0x04])
            ]
        )
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)

        var decodeFailed = false
        do {
            _ = try await client.selectAll("SELECT value", as: IntRow.self)
        } catch {
            decodeFailed = true
        }
        #expect(decodeFailed)

        try await client.ping()

        await client.close()
    }
}
