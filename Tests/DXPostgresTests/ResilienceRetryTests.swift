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

import Atomics
import Testing

@testable import DXPostgres

// Drives the retry loop directly with synthetic failures, so the backoff and
// classification logic is exercised without a server.
@Suite struct ResilienceRetryTests {

    private func makeClient(_ resilience: PostgresResilience) -> PostgresClient {
        PostgresClient(configuration: PostgresConfiguration(
            endpoint: PostgresEndpoint(host: "localhost"),
            credentials: .password(username: "u", password: "p"),
            database: PostgresDatabaseName("db"),
            resilience: resilience
        ))
    }

    @Test func retriesTransientFailuresThenSucceeds() async throws {
        let client = makeClient(PostgresResilience(retryTransientFailures: true, reconnectBaseDelay: .milliseconds(1), reconnectMaxDelay: .milliseconds(4)))
        let attempts = ManagedAtomic<Int>(0)
        let value = try await client.withResilience(statement: "SELECT 1") { () throws -> Int in
            let attempt = attempts.wrappingIncrementThenLoad(ordering: .relaxed)
            guard attempt >= 3 else { throw PostgresError.connectionClosed }
            return attempt
        }
        #expect(value == 3)
        #expect(attempts.load(ordering: .relaxed) == 3)
        let metrics = client.metrics()
        #expect(metrics.queriesTotal == 1)
        #expect(metrics.queryErrorsTotal == 0)
        #expect(metrics.retriesTotal == 2)
        await client.shutdown()
    }

    @Test func doesNotRetryNonTransientFailures() async {
        let client = makeClient(PostgresResilience())
        let attempts = ManagedAtomic<Int>(0)
        await #expect(throws: PostgresError.self) {
            try await client.withResilience(statement: "INSERT INTO t VALUES (1)") { () throws -> Int in
                attempts.wrappingIncrement(ordering: .relaxed)
                throw PostgresError.server(PostgresServerError(severity: "ERROR", sqlState: "23505", message: "duplicate"))
            }
        }
        #expect(attempts.load(ordering: .relaxed) == 1)
        #expect(client.metrics().queryErrorsTotal == 1)
        await client.shutdown()
    }

    @Test func disabledResilienceDoesNotRetry() async {
        let client = makeClient(.disabled)
        let attempts = ManagedAtomic<Int>(0)
        await #expect(throws: PostgresError.self) {
            try await client.withResilience(statement: "SELECT 1") { () throws -> Int in
                attempts.wrappingIncrement(ordering: .relaxed)
                throw PostgresError.connectionClosed
            }
        }
        #expect(attempts.load(ordering: .relaxed) == 1)
        await client.shutdown()
    }
}
