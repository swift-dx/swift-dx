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

@Suite("Redis database operations", .enabled(if: RedisIntegration.isEnabled), .serialized)
struct RedisDatabaseIntegrationTests {

    @Test("a database view isolates keys from the default database")
    func databaseViewIsolatesKeys() async throws {
        let client = try RedisIntegration.makeClient(database: 0)
        let key = RedisIntegration.uniqueKey("dbview")
        let other = try RedisDatabaseIndex(9)
        try await client.database(other).flush(.synchronous)
        try await client.database(other).set(key, to: "in-nine")
        #expect(try await client.getBytes(key) == Lookup<[UInt8]>.notFound)
        #expect(try await client.database(other).getString(key) == Lookup.found("in-nine"))
        try await client.database(other).flush(.synchronous)
        await client.shutdown()
    }

    @Test("swapDatabase atomically promotes staged data")
    func swapDatabasePromotesData() async throws {
        let client = try RedisIntegration.makeClient(database: 0)
        let live = try RedisDatabaseIndex(10)
        let staging = try RedisDatabaseIndex(11)
        let key = RedisIntegration.uniqueKey("swap")
        try await client.database(live).flush(.synchronous)
        try await client.database(staging).flush(.synchronous)
        try await client.database(staging).set(key, to: "staged")
        try await client.swapDatabase(live, with: staging)
        #expect(try await client.database(live).getString(key) == Lookup.found("staged"))
        #expect(try await client.database(staging).getBytes(key) == Lookup<[UInt8]>.notFound)
        try await client.database(live).flush(.synchronous)
        await client.shutdown()
    }

    @Test("a mid-batch error after a database switch does not corrupt the next operation's database")
    func databaseStaysConsistentAfterMidBatchError() async throws {
        let client = try RedisIntegration.makeClient(database: 0, maxConnections: 1)
        let other = try RedisDatabaseIndex(5)
        let key = RedisIntegration.uniqueKey("consistency")
        await #expect(throws: RedisError.self) {
            try await client.database(other).pipelineExpectingSuccess([
                RedisIntegration.setCommand("\(key)-probe", "1"),
                RedisCommand("DXREDIS_NOT_A_COMMAND"),
            ])
        }
        try await client.set(key, to: "zero")
        #expect(try await client.database(other).getBytes(key) == Lookup<[UInt8]>.notFound)
        #expect(try await client.getString(key) == Lookup.found("zero"))
        _ = try await client.delete([key])
        try await client.database(other).flush(.synchronous)
        await client.shutdown()
    }

    @Test("flushDatabase clears the selected database")
    func flushDatabaseClearsKeys() async throws {
        let client = try RedisIntegration.makeClient(database: 12)
        let key = RedisIntegration.uniqueKey("flush")
        try await client.set(key, to: "present")
        try await client.flushDatabase(.synchronous)
        #expect(try await client.getBytes(key) == Lookup<[UInt8]>.notFound)
        await client.shutdown()
    }
}
