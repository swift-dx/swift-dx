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

// A pool configured with preflightPing recycles an idle connection by
// round-tripping a Ping before handing it back. The connection's default
// reconnection policy is alwaysRetry (unbounded). If preflight routed
// through the reconnecting send/receive path, a probe against a broker
// that has gone away would loop inside reconnect forever and hang
// acquire() past its timeout. This test stands up an in-process server
// that completes one Native handshake and then vanishes, and asserts that
// acquiring from the pool afterwards fails with a typed error in bounded
// time rather than hanging.
@Suite("ClickHouseConnectionPool preflight does not hang on a dead connection")
struct PoolPreflightHangTests {

    @Test("acquire surfaces a typed failure quickly when preflight meets a dead connection", .timeLimit(.minutes(1)))
    func preflightDoesNotHang() async throws {
        let server = FakeClickHouseServer()
        // Revision below 54_058 keeps the ServerHello tail empty.
        server.run(serverHello: FakeClickHouseServer.serverHello(revision: 54_057), afterHandshake: .vanish)

        let configuration = ClickHouseConnectionPool.Configuration(
            host: "127.0.0.1",
            port: server.port,
            minConnections: 1,
            maxConnections: 1,
            acquireTimeout: .seconds(2),
            idleConnectionTTL: .seconds(300),
            maxConnectionLifetime: .seconds(3600),
            preflightPing: true,
            evictionInterval: .zero
        )
        let pool = try await ClickHouseConnectionPool(configuration: configuration)
        defer { Task { await pool.close() } }

        // The prewarmed idle connection is dead once the server vanishes.
        server.finished.wait()

        var threw = false
        do {
            try await pool.withConnection { _ in }
        } catch {
            threw = true
        }
        #expect(threw)
    }
}
