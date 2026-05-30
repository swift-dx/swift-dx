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

@Suite("Redis integration", .enabled(if: RedisIntegration.isEnabled), .serialized)
struct RedisIntegrationTests {

    private struct Profile: Codable, Equatable, Sendable {

        let id: Int
        let name: String
        let tags: [String]
    }

    @Test("ping reaches the server")
    func ping() async throws {
        let client = try RedisIntegration.makeClient()
        try await client.ping()
        await client.shutdown()
    }

    @Test("a byte value round-trips through set and get")
    func setGetBytes() async throws {
        let client = try RedisIntegration.makeClient()
        let key = RedisIntegration.uniqueKey("bytes")
        let value: [UInt8] = [0x00, 0x01, 0xfe, 0xff, 0x0d, 0x0a]
        try await client.set(key, to: value)
        #expect(try await client.getBytes(key) == Lookup.found(value))
        await client.shutdown()
    }

    @Test("a string value round-trips")
    func setGetString() async throws {
        let client = try RedisIntegration.makeClient()
        let key = RedisIntegration.uniqueKey("string")
        try await client.set(key, to: "hello world")
        #expect(try await client.getString(key) == Lookup.found("hello world"))
        await client.shutdown()
    }

    @Test("a ByteBuffer value round-trips")
    func setGetByteBuffer() async throws {
        let client = try RedisIntegration.makeClient()
        let key = RedisIntegration.uniqueKey("buffer")
        var buffer = ByteBuffer()
        buffer.writeString("buffered")
        try await client.set(key, to: buffer)
        #expect(try await client.getString(key) == Lookup.found("buffered"))
        await client.shutdown()
    }

    @Test("a missing key reads as notFound")
    func missingKey() async throws {
        let client = try RedisIntegration.makeClient()
        #expect(try await client.getBytes(RedisIntegration.uniqueKey("absent")) == Lookup<[UInt8]>.notFound)
        await client.shutdown()
    }

    @Test("a Codable value round-trips as JSON")
    func setGetJSON() async throws {
        let client = try RedisIntegration.makeClient()
        let key = RedisIntegration.uniqueKey("json")
        let profile = Profile(id: 7, name: "Ada", tags: ["a", "b"])
        try await client.set(key, toJSON: profile)
        #expect(try await client.get(key, asJSON: Profile.self) == Lookup.found(profile))
        await client.shutdown()
    }

    @Test("mset writes many keys that mget reads back, with holes as notFound")
    func multiSetMultiGet() async throws {
        let client = try RedisIntegration.makeClient()
        let prefix = RedisIntegration.uniquePrefix()
        let first = RedisKey("\(prefix):a")
        let second = RedisKey("\(prefix):b")
        let missing = RedisKey("\(prefix):missing")
        try await client.set([.init(key: first, value: "1"), .init(key: second, value: "2")])
        let results = try await client.get([first, missing, second])
        #expect(results == [Lookup.found(ByteBuffer(string: "1")), Lookup.notFound, Lookup.found(ByteBuffer(string: "2"))])
        await client.shutdown()
    }

    @Test("delete removes a key and exists reflects it")
    func deleteAndExists() async throws {
        let client = try RedisIntegration.makeClient()
        let key = RedisIntegration.uniqueKey("del")
        try await client.set(key, to: "v")
        #expect(try await client.exists(key))
        #expect(try await client.delete([key]) == 1)
        let stillThere = try await client.exists(key)
        #expect(!stillThere)
        await client.shutdown()
    }

    @Test("an arbitrary command returns its typed reply")
    func arbitraryCommand() async throws {
        let client = try RedisIntegration.makeClient()
        let key = RedisIntegration.uniqueKey("counter")
        let reply = try await client.send(RedisCommand(arguments: [Array("INCR".utf8), key.bytes]))
        #expect(try reply.integerValue() == 1)
        await client.shutdown()
    }

    @Test("an unknown command surfaces a server error")
    func unknownCommandThrows() async throws {
        let client = try RedisIntegration.makeClient()
        await #expect(throws: RedisError.self) {
            try await client.send(RedisCommand("DXREDIS_NOT_A_COMMAND"))
        }
        await client.shutdown()
    }

    @Test("a pipeline returns one reply per command in order")
    func pipelineReplies() async throws {
        let client = try RedisIntegration.makeClient()
        let key = RedisIntegration.uniqueKey("pipe")
        let replies = try await client.pipeline([
            RedisCommand(arguments: [Array("SET".utf8), key.bytes, Array("hello".utf8)]),
            RedisCommand(arguments: [Array("GET".utf8), key.bytes]),
        ])
        #expect(replies.count == 2)
        #expect(try replies[1].bytesValue() == Array("hello".utf8))
        await client.shutdown()
    }
}
