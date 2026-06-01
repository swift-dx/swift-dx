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

@testable import DXRedis
import Synchronization
import Testing

@Suite("Redis resilience")
struct RedisResilienceTests {

    private func makeClient(_ resilience: RedisResilience) -> RedisClient {
        RedisClient(configuration: RedisConfiguration(
            endpoint: RedisEndpoint(host: "127.0.0.1", port: 6399),
            resilience: resilience
        ))
    }

    @Test("the default policy retries; the disabled policy does not")
    func policyFlags() {
        #expect(RedisResilience().retryTransientFailures)
        #expect(RedisResilience().requestTimeout == .seconds(10))
        #expect(!RedisResilience.disabled.retryTransientFailures)
    }

    @Test("connection-layer failures are transient; server and caller errors are not")
    func transientClassification() {
        let transient: [RedisError] = [
            .connectionClosed, .transportError(reason: "x"),
            .incompleteResponse, .poolExhausted(maxConnections: 1),
        ]
        for error in transient {
            #expect(error.isTransient, "\(error) should be transient")
        }
        let permanent: [RedisError] = [
            .timedOut, .serverError(prefix: "ERR", message: "x"), .protocolError(reason: "x"), .unexpectedResponseType(expected: "a", actual: "b"),
            .malformedLength(reason: "x"), .authenticationFailed(reason: "x"), .lockNotAcquired, .cancelled,
            .invalidDatabaseIndex(1), .emptyCommand, .utf8DecodingFailed,
        ]
        for error in permanent {
            #expect(!error.isTransient, "\(error) should not be transient")
        }
    }

    @Test("the default policy retries a transient failure until the operation succeeds")
    func retriesTransientFailuresThenSucceeds() async throws {
        let client = makeClient(RedisResilience(reconnectBaseDelay: .milliseconds(1), reconnectMaxDelay: .milliseconds(4)))
        let attempts = Mutex(0)
        let value = try await client.withResilience(.fixed("TEST")) { () throws -> Int in
            let attempt = attempts.withLock { $0 += 1; return $0 }
            guard attempt >= 3 else { throw RedisError.connectionClosed }
            return attempt
        }
        #expect(value == 3)
        #expect(attempts.withLock { $0 } == 3)
        #expect(client.metrics().retriesTotal == 2)
        await client.shutdown()
    }

    @Test("a non-transient failure is surfaced on the first attempt")
    func nonTransientFailsImmediately() async {
        let client = makeClient(RedisResilience())
        let attempts = Mutex(0)
        await #expect(throws: RedisError.self) {
            try await client.withResilience(.fixed("TEST")) { () throws -> Int in
                attempts.withLock { $0 += 1 }
                throw RedisError.serverError(prefix: "ERR", message: "boom")
            }
        }
        #expect(attempts.withLock { $0 } == 1)
        #expect(client.metrics().retriesTotal == 0)
        await client.shutdown()
    }

    @Test("a permanently transient failure is surfaced after retrying within the budget")
    func permanentTransientSurfacesAfterRetrying() async {
        let client = makeClient(RedisResilience(requestTimeout: .milliseconds(200), reconnectBaseDelay: .milliseconds(1), reconnectMaxDelay: .milliseconds(4)))
        await #expect(throws: RedisError.self) {
            try await client.withResilience(.fixed("TEST")) { () throws -> Int in
                throw RedisError.connectionClosed
            }
        }
        #expect(client.metrics().retriesTotal >= 1)
        await client.shutdown()
    }

    @Test("the disabled policy makes a single attempt and does not retry")
    func disabledMakesOneAttempt() async {
        let client = makeClient(.disabled)
        let attempts = Mutex(0)
        await #expect(throws: RedisError.self) {
            try await client.withResilience(.fixed("TEST")) { () throws -> Int in
                attempts.withLock { $0 += 1 }
                throw RedisError.connectionClosed
            }
        }
        #expect(attempts.withLock { $0 } == 1)
        #expect(client.metrics().retriesTotal == 0)
        await client.shutdown()
    }
}
