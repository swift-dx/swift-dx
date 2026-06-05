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

// AsyncClickHouseConnection's non-streaming reads (drainBlocks, the scalar
// round-trip, the pings) run their blocking recv on the serial worker queue
// and bridge the result back through a checked continuation. Task
// cancellation does not resume a checked continuation on its own, so a caller
// whose task is cancelled while the worker is parked in recv — which happens
// whenever the server stalls and never sends EndOfStream — would await
// forever. The shared bridge must shut the socket down on cancellation so the
// parked recv fails fast and the await returns.
@Suite("a cancelled drainBlocks unblocks instead of awaiting forever")
struct CancelledDrainBlocksTeardownTests {

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

    @Test("cancelling a stalled drainBlocks task does not hang", .timeLimit(.minutes(1)))
    func cancelDrainBlocks() async throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(Self.oneRowBlock()), .awaitClientClose]
        )
        defer { server.stop() }

        let connection = try await AsyncClickHouseConnection(host: "127.0.0.1", port: server.port)
        try await connection.sendQuery("SELECT id FROM t")

        let task = Task { try await connection.drainBlocks() }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()

        var unblocked = false
        do {
            _ = try await task.value
            unblocked = true
        } catch {
            unblocked = true
        }

        await connection.close()

        #expect(unblocked)
    }
}
