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

// When the pool is saturated, an acquiring task parks in an FIFO waiter
// queue. If that task is cancelled (its request deadline elapsed, the
// caller gave up), it must observe the cancellation and return promptly,
// not stay blocked until the much longer acquire timeout fires. This
// stands up a one-connection pool, holds the single connection, parks a
// second acquire, cancels it, and asserts it returns well inside the
// acquire timeout.
@Suite("A cancelled pool acquire returns promptly instead of waiting for the timeout")
struct PoolAcquireCancellationTests {

    @Test("cancelling a parked acquire resumes it immediately with cancellation", .timeLimit(.minutes(1)))
    func cancelledAcquireReturnsPromptly() async throws {
        let server = FakeClickHouseServer()
        // Revision below 54_058 keeps the ServerHello tail empty; hold the
        // accepted socket open so the prewarmed connection stays usable.
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: 54_057),
            afterHandshake: .holdSilentCloseListener
        )
        defer { server.stop() }

        let configuration = ClickHouseConnectionPool.Configuration(
            host: "127.0.0.1",
            port: server.port,
            minConnections: 1,
            maxConnections: 1,
            acquireTimeout: .seconds(10),
            evictionInterval: .zero
        )
        let pool = try await ClickHouseConnectionPool(configuration: configuration)

        // Occupy the single connection for the duration of the test.
        let holder = Task {
            try await pool.withConnection { _ in
                try? await Task.sleep(for: .seconds(30))
            }
        }
        try await Task.sleep(for: .milliseconds(300))

        // This acquire parks behind the held connection.
        let waiter = Task { () -> String in
            do {
                try await pool.withConnection { _ in }
                return "acquired"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "other:\(error)"
            }
        }
        try await Task.sleep(for: .milliseconds(300))

        let clock = ContinuousClock()
        let start = clock.now
        waiter.cancel()
        let outcome = await waiter.value
        let elapsed = clock.now - start

        #expect(outcome == "cancelled")
        #expect(elapsed < .seconds(2))

        holder.cancel()
        _ = await holder.result
        await pool.close()
    }
}
