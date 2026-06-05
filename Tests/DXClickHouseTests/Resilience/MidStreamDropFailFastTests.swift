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

// When a connection drops while a result is streaming, the server's
// in-flight stream cannot be resumed on a fresh socket, so the read must
// fail fast. The recv path previously reconnected inline; under the
// default unbounded always-retry policy that reconnect loops until the
// broker returns, wedging the caller (and any pooled connection) for the
// whole outage to surface an error it was going to surface anyway. The
// fix closes the dead socket and throws immediately, deferring recovery
// to the next send. This test drops the broker entirely (client socket
// closed and listener closed) so an inline reconnect could never succeed,
// and asserts the read still returns promptly.
@Suite("A mid-stream connection drop fails the read fast instead of looping in reconnect")
struct MidStreamDropFailFastTests {

    @Test("a recv after the broker vanishes throws quickly under always-retry", .timeLimit(.minutes(1)))
    func recvFailsFastWhenBrokerVanishes() throws {
        let server = FakeClickHouseServer()
        // Revision below 54_058 keeps the ServerHello tail empty. `.vanish`
        // completes the handshake (so init succeeds), then closes the
        // client socket AND the listener, so any reconnect attempt is
        // refused — the condition under which the old inline reconnect
        // would loop forever.
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: 54_057),
            afterHandshake: .vanish
        )

        // Default policy is alwaysRetry (unbounded).
        nonisolated(unsafe) let connection = try ClickHouseConnection(host: "127.0.0.1", port: server.port)
        defer { connection.close() }

        // Make sure the server has fully vanished (client + listener closed)
        // before the read, so the recv sees EOF and any reconnect to the
        // now-closed port is refused rather than racing the teardown.
        server.finished.wait()

        let recvReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? connection.receiveScalarUInt64()
            recvReturned.signal()
        }

        // With the fix the parked read throws as soon as the recv fails;
        // without it the worker loops in reconnect against the closed
        // listener and never returns.
        let result = recvReturned.wait(timeout: .now() + 5)
        #expect(result == .success)
    }
}
