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

// AsyncClickHouseConnection.receiveBlocks() runs its receive loop on the
// connection's serial worker queue, the same shape as the client's streaming
// select. If the consumer cancels mid-stream while that loop is parked in a
// blocking recv — which happens whenever the server stalls and never sends
// EndOfStream — the worker must be torn down. Otherwise it blocks forever and
// every later operation, including close(), queues behind it and deadlocks.
@Suite("a cancelled receiveBlocks stream tears the parked worker down")
struct CancelledReceiveBlocksTeardownTests {

    // One data block carrying a single UInt8 row (id = 1): receiveBlocks
    // yields its body once, then loops back into recv for the next block,
    // where the stalled server leaves it parked.
    private static func oneRowBlock() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("id", into: &bytes)
        ClickHouseWire.writeString("UInt8", into: &bytes)
        bytes.append(0)
        bytes.append(1)
        return bytes
    }

    @Test("cancelling a stalled receiveBlocks does not hang close()", .timeLimit(.minutes(1)))
    func cancelDoesNotDeadlockClose() async throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(Self.oneRowBlock()), .awaitClientClose]
        )
        defer { server.stop() }

        let connection = try await AsyncClickHouseConnection(host: "127.0.0.1", port: server.port)
        try await connection.sendQuery("SELECT id FROM t")

        var observed = 0
        for try await _ in connection.receiveBlocks() {
            observed += 1
            break
        }

        await connection.close()

        #expect(observed == 1)
    }
}
