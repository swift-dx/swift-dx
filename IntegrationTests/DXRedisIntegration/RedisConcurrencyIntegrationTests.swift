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

// The production pattern: one shared client, many concurrent callers. Each task
// writes and reads back its own unique key, so any reply misrouting between
// concurrent operations would surface as a task seeing another task's value.
// The pool is sized to the concurrency so this isolates reply routing rather
// than pool contention.
@Suite("Redis shared-client concurrency", .enabled(if: RedisIntegration.isEnabled), .serialized)
struct RedisConcurrencyIntegrationTests {

    private func client() throws -> RedisClient {
        RedisClient(configuration: .init(
            endpoint: .init(host: RedisIntegration.host, port: RedisIntegration.port),
            database: try RedisDatabaseIndex(14),
            maxConnections: 64,
            maxIdleConnections: 64
        ))
    }

    @Test("a shared client keeps every concurrent caller's reply correctly routed")
    func sharedClientUnderConcurrency() async throws {
        let client = try client()
        let prefix = RedisIntegration.uniquePrefix()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<400 {
                group.addTask {
                    let key = RedisKey("\(prefix):\(index)")
                    let value = "value-\(index)"
                    try await client.set(key, to: value)
                    let read = try await client.getString(key)
                    guard read == Lookup.found(value) else {
                        throw RedisError.protocolError(reason: "task \(index) expected \(value) but read \(read)")
                    }
                }
            }
            for try await _ in group {}
        }
        await client.shutdown()
    }

    @Test("interleaved value and array reads on a shared client stay correctly routed")
    func mixedShapesUnderConcurrency() async throws {
        let client = try client()
        let prefix = RedisIntegration.uniquePrefix()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<300 {
                group.addTask {
                    let listKey = "\(prefix):list:\(index)"
                    _ = try await client.send(RedisCommand("RPUSH", listKey, "a-\(index)", "b-\(index)"))
                    let array = try await client.sendArray(RedisCommand("LRANGE", listKey, "0", "-1"))
                    guard array.count == 2, try array.stringLookup(at: 0) == Lookup.found("a-\(index)") else {
                        throw RedisError.protocolError(reason: "task \(index) saw a misrouted array reply")
                    }
                }
            }
            for try await _ in group {}
        }
        await client.shutdown()
    }
}
