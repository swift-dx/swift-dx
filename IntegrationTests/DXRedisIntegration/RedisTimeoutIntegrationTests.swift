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

import DXCore
import DXRedis
import NIOCore
import Testing

// Proves the per-request timeout has teeth against a live but unresponsive
// connection. BLPOP on an empty list parks the connection server-side for its
// own timeout; the client's shorter request timeout must fire first and surface
// RedisError.timedOut rather than hanging until the server returns.
@Suite("Redis request timeout", .enabled(if: RedisIntegration.isEnabled), .serialized)
struct RedisTimeoutIntegrationTests {

    private func client() throws -> RedisClient {
        RedisClient(configuration: .init(
            endpoint: .init(host: RedisIntegration.host, port: RedisIntegration.port),
            database: try RedisDatabaseIndex(15),
            resilience: RedisResilience(requestTimeout: .milliseconds(300), retryTransientFailures: false)
        ))
    }

    @Test("a command that outlives the request timeout fails with timedOut instead of hanging")
    func commandTimesOut() async throws {
        let client = try client()
        let emptyList = "\(RedisIntegration.uniquePrefix()):blpop"
        let start = ContinuousClock.now
        await #expect(throws: RedisError.timedOut) {
            _ = try await client.send(RedisCommand("BLPOP", emptyList, "5"))
        }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(2), "timeout should fire near 300ms, took \(elapsed)")
        await client.shutdown()
    }

    @Test("the connection is not reused after a timeout, so the next command still works")
    func recoversOnAFreshConnectionAfterTimeout() async throws {
        let client = try client()
        let emptyList = "\(RedisIntegration.uniquePrefix()):blpop"
        await #expect(throws: RedisError.timedOut) {
            _ = try await client.send(RedisCommand("BLPOP", emptyList, "5"))
        }
        let key = RedisIntegration.uniqueKey("after-timeout")
        try await client.set(key, to: "ok")
        #expect(try await client.getString(key) == Lookup.found("ok"))
        await client.shutdown()
    }
}
