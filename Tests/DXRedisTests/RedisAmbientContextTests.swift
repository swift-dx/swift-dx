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
import Testing

@Suite("Redis ambient context")
struct RedisAmbientContextTests {

    private func makeClient() -> RedisClient {
        RedisClient(configuration: .init(endpoint: .init(host: "127.0.0.1", port: 6399)))
    }

    @Test("current throws when no client is bound")
    func unboundThrows() {
        #expect(throws: RedisError.noCurrentClient) {
            _ = try Redis.current()
        }
    }

    @Test("withCurrent binds the client for the scope and current returns it")
    func boundReturnsClient() async throws {
        let client = makeClient()
        let resolved = try await Redis.withCurrent(client) {
            try Redis.current()
        }
        #expect(resolved === client)
        await client.shutdown()
    }

    @Test("the bound client propagates into child tasks")
    func propagatesToChildTask() async throws {
        let client = makeClient()
        let resolved = try await Redis.withCurrent(client) {
            try await Task { try Redis.current() }.value
        }
        #expect(resolved === client)
        await client.shutdown()
    }

    @Test("the binding does not leak outside its scope")
    func unboundAfterScope() async throws {
        let client = makeClient()
        _ = try await Redis.withCurrent(client) { try Redis.current() }
        #expect(throws: RedisError.noCurrentClient) {
            _ = try Redis.current()
        }
        await client.shutdown()
    }
}
