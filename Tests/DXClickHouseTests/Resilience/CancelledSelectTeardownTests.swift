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

// The streaming select runs its receive loop on the client's serial worker
// queue. If the consumer cancels mid-stream while that loop is parked in a
// blocking recv — which happens whenever the server stalls and never sends
// EndOfStream — the worker must be torn down. Otherwise it blocks forever and
// every later operation, including close(), queues behind it and deadlocks.
// The stream's cancellation handler must shut the socket down so the parked
// recv fails fast and the worker queue drains.
@Suite("a cancelled streaming select tears the parked worker down")
struct CancelledSelectTeardownTests {

    private struct Row: Codable, Sendable { let id: UInt8 }

    // One data block carrying a single UInt8 row (id = 1): the client decodes
    // and yields it, then loops back into recv for the next block, where the
    // stalled server leaves it parked.
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

    @Test("cancelling a stalled select does not hang close()", .timeLimit(.minutes(1)))
    func cancelDoesNotDeadlockClose() async throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(Self.oneRowBlock()), .awaitClientClose]
        )
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)

        var received: [UInt8] = []
        for try await row in client.select("SELECT id FROM t", as: Row.self) {
            received.append(row.id)
            break
        }

        await client.close()

        #expect(received == [1])
    }
}
