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

@Suite("Redis value types")
struct RedisValueTypeTests {

    @Test("a non-negative database index is accepted")
    func validDatabaseIndex() throws {
        #expect(try RedisDatabaseIndex(5).value == 5)
        #expect(RedisDatabaseIndex.zero.value == 0)
    }

    @Test("a negative database index throws")
    func negativeDatabaseIndex() {
        #expect(throws: RedisError.invalidDatabaseIndex(-1)) {
            try RedisDatabaseIndex(-1)
        }
    }

    @Test("a key built from text encodes as UTF-8 bytes")
    func keyFromText() {
        #expect(RedisKey("user:1").bytes == Array("user:1".utf8))
        #expect(RedisKey(bytes: [0x00, 0xff]).bytes == [0x00, 0xff])
    }

    @Test("a key built from a string literal matches the text initializer")
    func keyLiteral() {
        let literal: RedisKey = "session"
        #expect(literal == RedisKey("session"))
        #expect(literal.description == "session")
    }

    @Test("a command preserves its arguments in order")
    func commandArguments() {
        #expect(RedisCommand("GET", "k").arguments == [Array("GET".utf8), Array("k".utf8)])
        #expect(RedisCommand(words: ["A", "B"]).arguments == [Array("A".utf8), Array("B".utf8)])
        #expect(RedisCommand(arguments: [[1, 2]]).arguments == [[1, 2]])
    }

    @Test("a command can be built from an array literal")
    func commandArrayLiteral() {
        let command: RedisCommand = ["INCR", "counter"]
        #expect(command.arguments == [Array("INCR".utf8), Array("counter".utf8)])
    }

    @Test("a key-value pair stores key bytes and value bytes")
    func keyValuePair() {
        #expect(RedisKeyValuePair(key: "k", value: "v").value == Array("v".utf8))
        #expect(RedisKeyValuePair(key: "k", value: [9, 8]).value == [9, 8])
    }

    @Test("flush modes map to their wire tokens")
    func flushModeTokens() {
        #expect(RedisFlushMode.synchronous.token == "SYNC")
        #expect(RedisFlushMode.asynchronous.token == "ASYNC")
    }
}
