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
import Foundation
import Testing

// When a per-query timeout fires, the client calls shutdownSocketForTimeout
// to unblock the worker that is parked in a blocking recv. The worker's
// default reconnect policy is alwaysRetry (unbounded). If that
// shutdown-induced recv failure entered reconnect, it would loop forever
// against a broker that is no longer reachable, leaving the connection's
// worker spinning indefinitely and the connection permanently wedged. The
// shutdown must instead let the recv fail fast so the worker finishes.
@Suite("Timeout socket shutdown unblocks the worker without looping in reconnect")
struct QueryTimeoutHangTests {

    @Test("a recv parked when the broker vanishes fails fast after shutdownSocketForTimeout", .timeLimit(.minutes(1)))
    func shutdownDoesNotLoopReconnect() throws {
        let server = FakeClickHouseServer()
        // Revision below 54_058 keeps the ServerHello tail empty. The
        // server then holds the socket open but silent and closes its
        // listener, so any reconnect attempt is refused.
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: 54_057),
            afterHandshake: .holdSilentCloseListener
        )
        defer { server.stop() }

        // Default policy is alwaysRetry (unbounded) — the condition under
        // which the unfixed reconnect would loop forever.
        nonisolated(unsafe) let connection = try ClickHouseConnection(host: "127.0.0.1", port: server.port)
        defer { connection.close() }

        let recvReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? connection.receiveScalarUInt64()
            recvReturned.signal()
        }

        // Let the read park in recv against the silent server.
        Thread.sleep(forTimeInterval: 0.3)
        // Simulate the per-query timeout firing.
        connection.shutdownSocketForTimeout()

        // With the fix the parked recv throws immediately; without it the
        // worker loops in reconnect against the closed listener forever.
        let result = recvReturned.wait(timeout: .now() + 5)
        #expect(result == .success)
    }
}
