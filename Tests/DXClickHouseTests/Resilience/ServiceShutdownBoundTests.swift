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

// ClickHouseService promises that graceful shutdown drains in-flight work
// for at most shutdownGracePeriod and then closes regardless. The drain
// closes the client, which serialises through the connection's worker
// queue — so if a query is stuck in a blocking recv, a plain close can
// never run and the grace period bounds nothing. The deadline path must
// force the socket down to unblock the worker so shutdown actually
// completes.
@Suite("ClickHouseService shutdown is bounded even when a query is stuck")
struct ServiceShutdownBoundTests {

    @Test("drainThenClose returns within the grace period despite a parked query", .timeLimit(.minutes(1)))
    func shutdownBoundedWithStuckQuery() async throws {
        let server = FakeClickHouseServer()
        // Revision below 54_058 keeps the ServerHello tail empty; the
        // server then holds the socket open but silent so the query parks.
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: 54_057),
            afterHandshake: .holdSilentCloseListener
        )
        defer { server.stop() }

        let configuration = ClickHouseConfiguration(
            host: "127.0.0.1",
            port: server.port,
            shutdownGracePeriod: .milliseconds(500)
        )
        let service = try await ClickHouseService(configuration: configuration)

        // Park the worker: a zero-timeout query against the silent server
        // blocks in recv with no deadline of its own.
        let client = service.client
        let parked = Task { _ = try? await client.execute("SELECT 1", timeout: .zero) }
        defer { parked.cancel() }
        try await Task.sleep(for: .milliseconds(300))

        // Without the force-close on grace elapse this never returns.
        await service.drainThenClose()
    }
}
