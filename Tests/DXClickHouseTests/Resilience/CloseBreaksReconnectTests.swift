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

// Under the default always-retry policy, a worker that enters the reconnect
// backoff loop against a gone server would spin forever. close() must be able to
// stop it: the shutdown signal is stored before hopping onto the worker and the
// reconnect loop re-checks it every iteration, so a close() issued while the
// worker is mid-loop breaks the loop and returns instead of hanging behind it.
@Suite("close() stops a worker looping in unbounded reconnect")
struct CloseBreaksReconnectTests {

    private struct IntRow: Decodable, Sendable {

        let value: Int
    }

    @Test("close() returns while the worker loops in reconnect against a vanished server", .timeLimit(.minutes(1)))
    func closeBreaksReconnectLoop() async throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            afterHandshake: .vanish
        )
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)

        // The server vanished after the handshake, so this query's send fails and
        // the worker enters the unbounded reconnect backoff loop against a server
        // it can never reach again.
        do {
            _ = try await client.selectAll("SELECT 1", as: IntRow.self, timeout: .seconds(2))
        } catch {
            // Expected: the operation fails (timeout or connection failure).
        }

        // With the worker spinning in reconnect, close() must break the loop and
        // return. Before the fix the shutdown request was enqueued behind the
        // stuck worker and never ran, so close() hung past the time limit.
        await client.close()
    }

    @Test("AsyncClickHouseConnection.close() returns while the worker loops in reconnect", .timeLimit(.minutes(1)))
    func asyncConnectionCloseBreaksReconnectLoop() async throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            afterHandshake: .vanish
        )
        defer { server.stop() }

        let connection = try await AsyncClickHouseConnection(host: "127.0.0.1", port: server.port)

        // This send fails against the vanished server and drives the worker into
        // the unbounded reconnect loop; it never returns on its own, so it runs
        // detached while the test issues close().
        let looping = Task { try? await connection.sendQuery("SELECT 1") }
        try await Task.sleep(for: .milliseconds(300))

        // The pool closes its connections through this path; it must return even
        // while the worker is mid-loop, or the pool's own close() would hang.
        await connection.close()
        looping.cancel()
        _ = await looping.value
    }
}
