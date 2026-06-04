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

@testable import DXPostgresPrevious

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

    // A write whose connection drops mid-flight has an unknown outcome: the server
    // may have committed the row before the acknowledgement was lost. Replaying it
    // could insert a duplicate, so it fails fast after a single attempt rather than
    // retrying, even though the same failure is retryable for a read.
    @Test func doesNotRetryWriteAfterAmbiguousConnectionLoss() async {
        let client = makeClient(PostgresResilience(retryTransientFailures: true, reconnectBaseDelay: .milliseconds(1), reconnectMaxDelay: .milliseconds(4)))
        let attempts = ManagedAtomic<Int>(0)
        await #expect(throws: PostgresError.connectionClosed) {
            try await client.withResilience(statement: "INSERT INTO t (id) VALUES (1)") { () throws -> Int in
                attempts.wrappingIncrement(ordering: .relaxed)
                throw PostgresError.connectionClosed
            }
        }
        #expect(attempts.load(ordering: .relaxed) == 1)
        #expect(client.metrics().retriesTotal == 0)
        await client.shutdown()
    }

    // A read carries no persistent effect, so replaying it after an ambiguous
    // transport failure is safe and lets the loop heal a momentarily dead connection.
    @Test func retriesReadAfterAmbiguousConnectionLoss() async throws {
        let client = makeClient(PostgresResilience(retryTransientFailures: true, reconnectBaseDelay: .milliseconds(1), reconnectMaxDelay: .milliseconds(4)))
        let attempts = ManagedAtomic<Int>(0)
        let value = try await client.withResilience(statement: "SELECT id FROM t") { () throws -> Int in
            let attempt = attempts.wrappingIncrementThenLoad(ordering: .relaxed)
            guard attempt >= 2 else { throw PostgresError.transportError(reason: "connection reset by peer") }
            return attempt
        }
        #expect(value == 2)
        await client.shutdown()
    }

    // Acquisition failures occur before any statement reaches the server, so even a
    // write retries them safely: nothing could have been applied yet.
    @Test func retriesWriteOnAcquisitionFailure() async throws {
        let client = makeClient(PostgresResilience(retryTransientFailures: true, reconnectBaseDelay: .milliseconds(1), reconnectMaxDelay: .milliseconds(4)))
        let attempts = ManagedAtomic<Int>(0)
        let value = try await client.withResilience(statement: "INSERT INTO t (id) VALUES (1)") { () throws -> Int in
            let attempt = attempts.wrappingIncrementThenLoad(ordering: .relaxed)
            guard attempt >= 2 else { throw PostgresError.poolExhausted(maxConnections: 4) }
            return attempt
        }
        #expect(value == 2)
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
