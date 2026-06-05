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

// After a client is closed, an operation must fail fast rather than
// transparently revive the connection. Under the default always-retry
// policy a post-close operation would otherwise drop into the unbounded
// reconnect loop against the gone endpoint. The reconnect loop runs on
// the worker queue and is not preempted by the caller's query timeout,
// so the operation never returns: the worker spins forever and the
// caller is parked indefinitely. A closed connection now rejects the
// reconnect immediately with a typed connection-closed error.
@Suite("Operations after close fail fast instead of reviving the connection")
struct UseAfterCloseTests {

    @Test("execute after close throws a closed-connection error, not a query timeout", .timeLimit(.minutes(1)))
    func executeAfterCloseFailsFast() async throws {
        let server = FakeClickHouseServer()
        // Revision below 54_058 keeps the ServerHello tail empty; the server
        // completes the handshake then vanishes (closes the client socket
        // and the listener), so any reconnect is refused.
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: 54_057),
            afterHandshake: .vanish
        )

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        await client.close()

        var caught: ClickHouseError = .reconnectExhausted(attempts: -1)
        var threw = false
        do {
            // A short timeout: without the fix the operation loops in
            // reconnect and surfaces queryTimeout here; with the fix it
            // rejects immediately with connectionFailed.
            try await client.execute("SELECT 1", timeout: .seconds(2))
        } catch {
            caught = error
            threw = true
        }

        #expect(threw)
        guard case .connectionFailed(let reason) = caught else {
            Issue.record("expected connectionFailed after close, got \(caught)")
            return
        }
        #expect(reason.contains("closed"))
    }
}
