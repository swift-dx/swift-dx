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
import NIOCore
import Testing

@Suite("Redis resilience")
struct RedisResilienceTests {

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

    @Test("a transient failure is retried until the request timeout elapses, then surfaced")
    func retriesUntilTimeout() async throws {
        let configuration = RedisConfiguration(
            endpoint: RedisEndpoint(host: "127.0.0.1", port: 6399),
            connectTimeout: .milliseconds(200),
            resilience: RedisResilience(requestTimeout: .milliseconds(400), reconnectBaseDelay: .milliseconds(20), reconnectMaxDelay: .milliseconds(80))
        )
        let client = RedisClient(configuration: configuration)
        let start = ContinuousClock.now
        await #expect(throws: RedisError.self) {
            _ = try await client.getBytes(RedisKey("absent"))
        }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed > .milliseconds(300), "expected the client to retry across the request timeout, took \(elapsed)")
        #expect(client.metrics().retriesTotal > 0)
        await client.shutdown()
    }

    @Test("the disabled policy fails on the first transient error without retrying")
    func disabledFailsFast() async throws {
        let configuration = RedisConfiguration(
            endpoint: RedisEndpoint(host: "127.0.0.1", port: 6399),
            connectTimeout: .milliseconds(200),
            resilience: .disabled
        )
        let client = RedisClient(configuration: configuration)
        await #expect(throws: RedisError.self) {
            _ = try await client.getBytes(RedisKey("absent"))
        }
        #expect(client.metrics().retriesTotal == 0)
        await client.shutdown()
    }
}
