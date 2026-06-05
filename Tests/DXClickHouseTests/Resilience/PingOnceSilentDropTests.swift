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

// pingOnce is the pool's preflight probe for a recycled idle connection.
// If the peer vanished without sending a FIN (network partition, firewall
// drop) the connection is half-open: the probe's Pong recv would block
// until the OS TCP retransmit timeout (minutes), hanging preflight and
// every acquire() waiting on that connection. The probe must bound its
// recv so a silently-dead connection fails fast and is discarded. This
// completes the handshake, then holds the socket open and silent (no Pong,
// no FIN), and asserts pingOnce returns well inside the configured timeout.
@Suite("pingOnce fails fast against a silently-dropped peer")
struct PingOnceSilentDropTests {

    @Test("a half-open connection's preflight ping times out instead of hanging", .timeLimit(.minutes(1)))
    func pingOnceDoesNotHangOnSilentPeer() throws {
        let server = FakeClickHouseServer()
        // Revision below 54_058 keeps the ServerHello tail empty; the server
        // completes the handshake, then holds the socket open and silent.
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: 54_057),
            afterHandshake: .holdSilentCloseListener
        )
        defer { server.stop() }

        // Short handshake timeout doubles as the preflight probe bound.
        let policy = ReconnectionPolicy(
            maxAttempts: ReconnectionPolicy.unboundedAttempts,
            initialBackoff: .milliseconds(100),
            maxBackoff: .seconds(5),
            backoffMultiplier: 2.0,
            handshakeTimeout: .seconds(1)
        )
        nonisolated(unsafe) let connection = try ClickHouseConnection(
            host: "127.0.0.1",
            port: server.port,
            reconnectionPolicy: policy
        )
        defer { connection.close() }

        let pingReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? connection.pingOnce()
            pingReturned.signal()
        }

        // With the fix the probe's recv times out (~1s) and pingOnce throws;
        // without it the recv blocks indefinitely against the silent peer.
        let result = pingReturned.wait(timeout: .now() + 5)
        #expect(result == .success)
    }
}
