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

extension RedisCommand {

    static func get(_ key: RedisKey) -> RedisCommand {
        RedisCommand(arguments: [Array("GET".utf8), key.bytes])
    }

    static func set(_ key: RedisKey, value: [UInt8]) -> RedisCommand {
        RedisCommand(arguments: [Array("SET".utf8), key.bytes, value])
    }

    static func set(_ key: RedisKey, value: [UInt8], condition: RedisSetCondition, expiration: RedisExpiration) -> RedisCommand {
        RedisCommand(arguments: [Array("SET".utf8), key.bytes, value] + condition.arguments + expiration.arguments)
    }

    static func expire(_ key: RedisKey, seconds: Int) -> RedisCommand {
        RedisCommand(arguments: [Array("EXPIRE".utf8), key.bytes, Array(String(seconds).utf8)])
    }

    static func expire(_ key: RedisKey, milliseconds: Int) -> RedisCommand {
        RedisCommand(arguments: [Array("PEXPIRE".utf8), key.bytes, Array(String(milliseconds).utf8)])
    }

    static func persist(_ key: RedisKey) -> RedisCommand {
        RedisCommand(arguments: [Array("PERSIST".utf8), key.bytes])
    }

    static func timeToLive(_ key: RedisKey) -> RedisCommand {
        RedisCommand(arguments: [Array("PTTL".utf8), key.bytes])
    }

    static func evaluate(script: String, keys: [RedisKey], arguments: [[UInt8]]) -> RedisCommand {
        var parts: [[UInt8]] = [Array("EVAL".utf8), Array(script.utf8), Array(String(keys.count).utf8)]
        parts.append(contentsOf: keys.map(\.bytes))
        parts.append(contentsOf: arguments)
        return RedisCommand(arguments: parts)
    }

    static func delete(_ keys: [RedisKey]) -> RedisCommand {
        RedisCommand(arguments: [Array("DEL".utf8)] + keys.map(\.bytes))
    }

    static func exists(_ keys: [RedisKey]) -> RedisCommand {
        RedisCommand(arguments: [Array("EXISTS".utf8)] + keys.map(\.bytes))
    }

    static func multiSet(_ pairs: [RedisKeyValuePair]) -> RedisCommand {
        RedisCommand(arguments: [Array("MSET".utf8)] + pairs.flatMap { [$0.key.bytes, $0.value] })
    }

    static func multiGet(_ keys: [RedisKey]) -> RedisCommand {
        RedisCommand(arguments: [Array("MGET".utf8)] + keys.map(\.bytes))
    }

    static func selectDatabase(_ index: Int) -> RedisCommand {
        RedisCommand(arguments: [Array("SELECT".utf8), Array(String(index).utf8)])
    }

    static func swapDatabase(_ first: Int, _ second: Int) -> RedisCommand {
        RedisCommand(arguments: [Array("SWAPDB".utf8), Array(String(first).utf8), Array(String(second).utf8)])
    }

    static func flushDatabase(_ mode: RedisFlushMode) -> RedisCommand {
        RedisCommand("FLUSHDB", mode.token)
    }

    static func flushAll(_ mode: RedisFlushMode) -> RedisCommand {
        RedisCommand("FLUSHALL", mode.token)
    }

    static func ping() -> RedisCommand {
        RedisCommand("PING")
    }

    static func authenticate(password: String) -> RedisCommand {
        RedisCommand("AUTH", password)
    }

    static func authenticate(username: String, password: String) -> RedisCommand {
        RedisCommand("AUTH", username, password)
    }
}
