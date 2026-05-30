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
import Testing

@Suite("Redis pipelining", .enabled(if: RedisIntegration.isEnabled), .serialized)
struct RedisPipeliningIntegrationTests {

    @Test("pipelineExpectingSuccess writes a batch and surfaces no errors")
    func pipelineExpectingSuccessWritesBatch() async throws {
        let client = try RedisIntegration.makeClient(database: 13)
        try await client.flushDatabase(.synchronous)
        let prefix = RedisIntegration.uniquePrefix()
        let commands = (0..<200).map { RedisIntegration.setCommand("\(prefix):\($0)", "\($0)") }
        try await client.pipelineExpectingSuccess(commands)
        #expect(try await client.getString(RedisKey("\(prefix):142")) == Lookup.found("142"))
        try await client.flushDatabase(.synchronous)
        await client.shutdown()
    }

    @Test("setPipelined writes fifty thousand keys in one pipeline")
    func setPipelinedLargeBatch() async throws {
        let client = try RedisIntegration.makeClient(database: 13)
        try await client.flushDatabase(.synchronous)
        let prefix = RedisIntegration.uniquePrefix()
        let count = 50_000
        let pairs = (0..<count).map { RedisKeyValuePair(key: RedisKey("\(prefix):\($0)"), value: "\($0)") }
        try await client.setPipelined(pairs)
        #expect(try await client.getString(RedisKey("\(prefix):0")) == Lookup.found("0"))
        #expect(try await client.getString(RedisKey("\(prefix):49999")) == Lookup.found("49999"))
        let size = try await client.send(RedisCommand("DBSIZE")).integerValue()
        #expect(size >= Int64(count))
        try await client.flushDatabase(.synchronous)
        await client.shutdown()
    }

    @Test("mset writes a thousand keys atomically")
    func msetAtomicBatch() async throws {
        let client = try RedisIntegration.makeClient(database: 13)
        try await client.flushDatabase(.synchronous)
        let prefix = RedisIntegration.uniquePrefix()
        let pairs = (0..<1000).map { RedisKeyValuePair(key: RedisKey("\(prefix):\($0)"), value: "v\($0)") }
        try await client.set(pairs)
        #expect(try await client.getString(RedisKey("\(prefix):500")) == Lookup.found("v500"))
        try await client.flushDatabase(.synchronous)
        await client.shutdown()
    }

    @Test("eight concurrent tasks pipeline through the shared pool")
    func concurrentPipelinesShareThePool() async throws {
        let client = try RedisIntegration.makeClient(database: 13, maxConnections: 8)
        try await client.flushDatabase(.synchronous)
        let prefix = RedisIntegration.uniquePrefix()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for task in 0..<8 {
                group.addTask {
                    let pairs = (0..<1000).map { RedisKeyValuePair(key: RedisKey("\(prefix):\(task):\($0)"), value: "\($0)") }
                    try await client.setPipelined(pairs)
                }
            }
            try await group.waitForAll()
        }
        #expect(try await client.getString(RedisKey("\(prefix):3:500")) == Lookup.found("500"))
        try await client.flushDatabase(.synchronous)
        await client.shutdown()
    }
}
