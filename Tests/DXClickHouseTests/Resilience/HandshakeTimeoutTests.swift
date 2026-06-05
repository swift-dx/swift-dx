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

// connect() succeeding does not mean the server will complete the Native
// handshake. A server (or a load balancer in front of it) can accept the
// TCP connection and then never answer the Hello. Without a bound on the
// handshake recv, ClickHouseConnection.init parks forever and every caller
// above it (pool, client, service) hangs with it. The handshake must be
// bounded by the policy's handshakeTimeout.
@Suite("Connect handshake is bounded when the server never answers Hello")
struct HandshakeTimeoutTests {

    @Test("init fails fast against a server that accepts but stalls the handshake", .timeLimit(.minutes(1)))
    func handshakeStallFailsFast() throws {
        let server = FakeClickHouseServer()
        server.runStallingHandshake()
        defer { server.stop() }

        let policy = ReconnectionPolicy(
            maxAttempts: 0,
            initialBackoff: .zero,
            maxBackoff: .zero,
            handshakeTimeout: .milliseconds(500)
        )

        var threw = false
        do {
            let connection = try ClickHouseConnection(host: "127.0.0.1", port: server.port, reconnectionPolicy: policy)
            connection.close()
        } catch {
            threw = true
        }
        #expect(threw)
    }
}
