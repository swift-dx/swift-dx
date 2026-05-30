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

@Suite("Redis command factory")
struct RedisCommandFactoryTests {

    private func bytes(_ tokens: String...) -> [[UInt8]] {
        tokens.map { Array($0.utf8) }
    }

    @Test("GET builds the verb and key")
    func get() {
        #expect(RedisCommand.get("k").arguments == bytes("GET", "k"))
    }

    @Test("SET builds the verb, key, and value")
    func set() {
        #expect(RedisCommand.set("k", value: [1, 2]).arguments == [Array("SET".utf8), Array("k".utf8), [1, 2]])
    }

    @Test("DEL spreads all keys")
    func delete() {
        #expect(RedisCommand.delete(["a", "b"]).arguments == bytes("DEL", "a", "b"))
    }

    @Test("EXISTS spreads all keys")
    func exists() {
        #expect(RedisCommand.exists(["a"]).arguments == bytes("EXISTS", "a"))
    }

    @Test("MSET interleaves keys and values")
    func multiSet() {
        let command = RedisCommand.multiSet([.init(key: "k", value: [5])])
        #expect(command.arguments == [Array("MSET".utf8), Array("k".utf8), [5]])
    }

    @Test("MGET spreads all keys")
    func multiGet() {
        #expect(RedisCommand.multiGet(["a", "b"]).arguments == bytes("MGET", "a", "b"))
    }

    @Test("SELECT renders the index as ASCII digits")
    func selectDatabase() {
        #expect(RedisCommand.selectDatabase(12).arguments == bytes("SELECT", "12"))
    }

    @Test("SWAPDB renders both indices")
    func swapDatabase() {
        #expect(RedisCommand.swapDatabase(0, 1).arguments == bytes("SWAPDB", "0", "1"))
    }

    @Test("FLUSHDB and FLUSHALL carry their mode token")
    func flush() {
        #expect(RedisCommand.flushDatabase(.asynchronous).arguments == bytes("FLUSHDB", "ASYNC"))
        #expect(RedisCommand.flushAll(.synchronous).arguments == bytes("FLUSHALL", "SYNC"))
    }

    @Test("PING has only the verb")
    func ping() {
        #expect(RedisCommand.ping().arguments == bytes("PING"))
    }

    @Test("AUTH builds password-only and username-password forms")
    func authenticate() {
        #expect(RedisCommand.authenticate(password: "p").arguments == bytes("AUTH", "p"))
        #expect(RedisCommand.authenticate(username: "u", password: "p").arguments == bytes("AUTH", "u", "p"))
    }
}
