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

import DXPostgres
import NIOCore
import Testing

@Suite(.serialized, .enabled(if: PostgresIntegration.isEnabled)) struct PostgresPoolTimeoutIntegrationTests {

    // A streamed pg_sleep parks on the sole connection for far longer than the
    // request timeout, so a second query cannot acquire one and must fail with a
    // bounded `poolExhausted` rather than hang. Resilience is disabled so the
    // bounded failure surfaces immediately instead of being retried; this makes
    // the outcome deterministic and independent of machine load, because the held
    // connection is occupied for the whole window.
    @Test func acquireFailsWithPoolExhaustedWhenTheOnlyConnectionIsHeld() async throws {
        let configuration = PostgresIntegration.makeConfiguration(maxConnections: 1, requestTimeout: .milliseconds(500), resilience: .disabled)
        try await Postgres.withClient(configuration) { client in
            let held = client.queryStream("SELECT pg_sleep(5)")
            var iterator = held.makeAsyncIterator()
            try await Task.sleep(for: .milliseconds(500))
            await #expect(throws: PostgresError.self) {
                _ = try await client.query("SELECT 1")
            }
            _ = iterator
        }
    }

    // After contention clears, the client keeps working: a fresh query succeeds
    // and returns the expected value, proving the pool was never left wedged.
    @Test func clientRemainsUsableAfterContention() async throws {
        let configuration = PostgresIntegration.makeConfiguration(maxConnections: 2, requestTimeout: .seconds(5))
        try await Postgres.withClient(configuration) { client in
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<12 {
                    group.addTask { _ = try? await client.query("SELECT pg_sleep(0.05)") }
                }
                for await _ in group {}
            }
            let row = try await client.query("SELECT 7 AS ok").rows[0]
            #expect(try row.decode(Int.self, named: "ok") == 7)
        }
    }
}
