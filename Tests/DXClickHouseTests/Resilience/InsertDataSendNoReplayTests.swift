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
import Dispatch
import Testing

// sendQuery is the only safe retry point: when its send fails the
// connection re-handshakes and replays the query on the fresh socket.
// The INSERT data block and its terminator are different — they are only
// meaningful in the middle of an exchange that a prior sendQuery already
// opened. Replaying them on a freshly handshaked socket (which never
// received the INSERT query) feeds the server an unexpected packet and
// desyncs the stream. Worse, under the default unbounded always-retry
// policy a data-send failure against a gone broker would loop in
// reconnect forever. sendRawBytes must therefore fail fast, not reconnect.
@Suite("INSERT data sends fail fast instead of reconnecting and replaying")
struct InsertDataSendNoReplayTests {

    @Test("sendRawBytes does not reconnect-and-replay when the broker has vanished", .timeLimit(.minutes(1)))
    func dataSendFailsFastAfterBrokerVanishes() throws {
        let server = FakeClickHouseServer()
        // Handshake succeeds, then both the client socket and the listener
        // close: any reconnect attempt is refused, so a reconnecting send
        // would loop forever under always-retry.
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: 54_057),
            afterHandshake: .vanish
        )

        nonisolated(unsafe) let connection = try ClickHouseConnection(host: "127.0.0.1", port: server.port)
        defer { connection.close() }
        server.finished.wait()

        // Break the connection through the recv path: this tears the socket
        // down without reconnecting, so the following send starts from a
        // closed socket.
        _ = try? connection.receiveScalarUInt64()

        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? connection.sendRawBytes([0x02, 0x00])
            returned.signal()
        }

        // With the fix the data send fails immediately; without it the send
        // reconnects against the closed listener and the always-retry loop
        // never returns.
        let result = returned.wait(timeout: .now() + 5)
        #expect(result == .success)
    }
}
