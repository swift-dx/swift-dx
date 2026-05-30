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

import Logging

extension RedisClient {

    // Acquires a distributed lock with `SET key token NX PX ttl`: the lock is set
    // only if the key is absent, and it carries an expiry so a holder that dies
    // never deadlocks the key. The returned outcome distinguishes acquisition from
    // contention without an optional.
    public func acquireLock(_ key: RedisKey, expiresInMilliseconds milliseconds: Int) async throws(RedisError) -> RedisLockOutcome {
        let token = RedisLockToken.random()
        let acquired = try await conditionalSet(key, value: token.bytes, condition: .ifAbsent, expiration: .milliseconds(milliseconds), database: defaultDatabase)
        return Self.lockOutcome(acquired: acquired, key: key, token: token, client: self, database: defaultDatabase)
    }

    // Runs `body` while holding the lock, releasing it on both success and failure.
    // Throws `lockNotAcquired` when the lock is already held.
    public func withLock<Result>(_ key: RedisKey, expiresInMilliseconds milliseconds: Int, _ body: () async throws -> Result) async throws -> Result {
        switch try await acquireLock(key, expiresInMilliseconds: milliseconds) {
        case .contended: throw RedisError.lockNotAcquired
        case .acquired(let lock): return try await runUnderLock(lock, body)
        }
    }

    func releaseLock(_ key: RedisKey, token: RedisLockToken, database: RedisDatabaseIndex) async throws(RedisError) -> Bool {
        let value = try await evaluateLockScript(Self.releaseScript, key: key, arguments: [token.bytes], database: database)
        return value == 1
    }

    func extendLock(_ key: RedisKey, token: RedisLockToken, milliseconds: Int, database: RedisDatabaseIndex) async throws(RedisError) -> Bool {
        let value = try await evaluateLockScript(Self.extendScript, key: key, arguments: [token.bytes, Array(String(milliseconds).utf8)], database: database)
        return value == 1
    }

    private func evaluateLockScript(_ script: String, key: RedisKey, arguments: [[UInt8]], database: RedisDatabaseIndex) async throws(RedisError) -> Int64 {
        let reply = try await execute(.evaluate(script: script, keys: [key], arguments: arguments), on: database)
        return try reply.integerValue()
    }

    private func runUnderLock<Result>(_ lock: RedisLock, _ body: () async throws -> Result) async throws -> Result {
        do {
            let result = try await body()
            await releaseQuietly(lock)
            return result
        } catch {
            await releaseQuietly(lock)
            throw error
        }
    }

    private func releaseQuietly(_ lock: RedisLock) async {
        do {
            _ = try await lock.release()
        } catch {
            logger.warning("lock release failed; the lock will expire on its own", metadata: ["error": .string(String(describing: error))])
        }
    }

    private static func lockOutcome(acquired: Bool, key: RedisKey, token: RedisLockToken, client: RedisClient, database: RedisDatabaseIndex) -> RedisLockOutcome {
        guard acquired else { return .contended }
        return .acquired(RedisLock(key: key, token: token, client: client, database: database))
    }

    static var releaseScript: String {
        #"if redis.call("GET", KEYS[1]) == ARGV[1] then return redis.call("DEL", KEYS[1]) else return 0 end"#
    }

    static var extendScript: String {
        #"if redis.call("GET", KEYS[1]) == ARGV[1] then return redis.call("PEXPIRE", KEYS[1], ARGV[2]) else return 0 end"#
    }
}
