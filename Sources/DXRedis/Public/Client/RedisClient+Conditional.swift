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

extension RedisClient {

    // Conditional set. Returns true when the value was written, false when the
    // condition prevented it (`.ifAbsent` against an existing key, `.ifPresent`
    // against a missing key) — Redis answers a null bulk in that case, which is a
    // normal outcome, not an error.
    public func set(_ key: RedisKey, to value: [UInt8], condition: RedisSetCondition, expiration: RedisExpiration) async throws(RedisError) -> Bool {
        try await conditionalSet(key, value: value, condition: condition, expiration: expiration, database: defaultDatabase)
    }

    public func set(_ key: RedisKey, to value: String, condition: RedisSetCondition, expiration: RedisExpiration) async throws(RedisError) -> Bool {
        try await conditionalSet(key, value: Array(value.utf8), condition: condition, expiration: expiration, database: defaultDatabase)
    }

    public func setIfAbsent(_ key: RedisKey, to value: [UInt8], expiration: RedisExpiration) async throws(RedisError) -> Bool {
        try await conditionalSet(key, value: value, condition: .ifAbsent, expiration: expiration, database: defaultDatabase)
    }

    public func expire(_ key: RedisKey, seconds: Int) async throws(RedisError) -> Bool {
        try await booleanReply(.expire(key, seconds: seconds))
    }

    public func expire(_ key: RedisKey, milliseconds: Int) async throws(RedisError) -> Bool {
        try await booleanReply(.expire(key, milliseconds: milliseconds))
    }

    public func persist(_ key: RedisKey) async throws(RedisError) -> Bool {
        try await booleanReply(.persist(key))
    }

    public func timeToLive(_ key: RedisKey) async throws(RedisError) -> RedisTimeToLive {
        let raw = try await send(.timeToLive(key)).integerValue()
        return RedisTimeToLive.decode(raw)
    }

    func conditionalSet(_ key: RedisKey, value: [UInt8], condition: RedisSetCondition, expiration: RedisExpiration, database: RedisDatabaseIndex) async throws(RedisError) -> Bool {
        let reply = try await execute(.set(key, value: value, condition: condition, expiration: expiration), on: database)
        return try Self.interpretConditionalSet(reply)
    }

    private func booleanReply(_ command: RedisCommand) async throws(RedisError) -> Bool {
        let value = try await send(command).integerValue()
        return value == 1
    }

    private static func interpretConditionalSet(_ reply: RESPValue) throws(RedisError) -> Bool {
        switch reply {
        case .simpleString: true
        case .null: false
        case .error(let prefix, let message): throw RedisError.serverError(prefix: prefix, message: message)
        case .bulkString, .integer, .array, .arrayReply: throw RedisError.unexpectedResponseType(expected: "OK or null", actual: reply.kindName)
        }
    }
}
