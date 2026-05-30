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

@Suite("Redis conditional writes and locking", .enabled(if: RedisIntegration.isEnabled), .serialized)
struct RedisLockIntegrationTests {

    @Test("setIfAbsent writes once and then reports contention")
    func setIfAbsent() async throws {
        let client = try RedisIntegration.makeClient(database: 14)
        let key = RedisIntegration.uniqueKey("nx")
        #expect(try await client.setIfAbsent(key, to: Array("first".utf8), expiration: .seconds(60)))
        #expect(!(try await client.setIfAbsent(key, to: Array("second".utf8), expiration: .seconds(60))))
        #expect(try await client.getString(key) == Lookup.found("first"))
        _ = try await client.delete([key])
        await client.shutdown()
    }

    @Test("setIfPresent only writes when the key exists")
    func setIfPresent() async throws {
        let client = try RedisIntegration.makeClient(database: 14)
        let key = RedisIntegration.uniqueKey("xx")
        #expect(!(try await client.set(key, to: "v1", condition: .ifPresent, expiration: .persist)))
        try await client.set(key, to: "seed")
        #expect(try await client.set(key, to: "v2", condition: .ifPresent, expiration: .persist))
        #expect(try await client.getString(key) == Lookup.found("v2"))
        _ = try await client.delete([key])
        await client.shutdown()
    }

    @Test("a set with expiry reports a positive time to live, persist clears it")
    func expiryAndPersist() async throws {
        let client = try RedisIntegration.makeClient(database: 14)
        let key = RedisIntegration.uniqueKey("ttl")
        _ = try await client.set(key, to: "v", condition: .always, expiration: .seconds(100))
        guard case .milliseconds(let remaining) = try await client.timeToLive(key) else {
            Issue.record("expected a millisecond TTL")
            await client.shutdown()
            return
        }
        #expect(remaining > 0 && remaining <= 100_000)
        #expect(try await client.persist(key))
        #expect(try await client.timeToLive(key) == .noExpiry)
        _ = try await client.delete([key])
        await client.shutdown()
    }

    @Test("time to live of a missing key is keyMissing")
    func timeToLiveMissing() async throws {
        let client = try RedisIntegration.makeClient(database: 14)
        #expect(try await client.timeToLive(RedisIntegration.uniqueKey("absent")) == .keyMissing)
        await client.shutdown()
    }

    @Test("a lock is acquired once, contended while held, and re-acquirable after release")
    func acquireContendRelease() async throws {
        let client = try RedisIntegration.makeClient(database: 14)
        let key = RedisIntegration.uniqueKey("lock")
        let lockOutcome = try await Self.acquireContendReleaseSequence(client: client, key: key)
        if lockOutcome == .completed {
            _ = try await client.delete([key])
        }
        await client.shutdown()
    }

    private enum LockSequenceOutcome: Sendable, Equatable {

        case completed
        case aborted

    }

    private static func acquireContendReleaseSequence(client: RedisClient, key: RedisKey) async throws -> LockSequenceOutcome {
        guard case .acquired(let lock) = try await client.acquireLock(key, expiresInMilliseconds: 30_000) else {
            Issue.record("expected to acquire the lock")
            return .aborted
        }
        return try await Self.contendReleaseReAcquire(client: client, key: key, lock: lock)
    }

    private static func contendReleaseReAcquire(client: RedisClient, key: RedisKey, lock: RedisLock) async throws -> LockSequenceOutcome {
        guard case .contended = try await client.acquireLock(key, expiresInMilliseconds: 30_000) else {
            Issue.record("expected contention while held")
            return .aborted
        }
        #expect(try await lock.release())
        guard case .acquired = try await client.acquireLock(key, expiresInMilliseconds: 30_000) else {
            Issue.record("expected to re-acquire after release")
            return .aborted
        }
        return .completed
    }

    @Test("release is token-safe: it does not delete a key now owned by someone else")
    func releaseIsTokenSafe() async throws {
        let client = try RedisIntegration.makeClient(database: 14)
        let key = RedisIntegration.uniqueKey("lock-safe")
        guard case .acquired(let lock) = try await client.acquireLock(key, expiresInMilliseconds: 30_000) else {
            Issue.record("expected to acquire the lock")
            await client.shutdown()
            return
        }
        try await client.set(key, to: "taken-by-another-holder")
        #expect(!(try await lock.release()))
        #expect(try await client.getString(key) == Lookup.found("taken-by-another-holder"))
        _ = try await client.delete([key])
        await client.shutdown()
    }

    @Test("withLock runs the body, releases, and throws when the lock is held")
    func withLock() async throws {
        let client = try RedisIntegration.makeClient(database: 14)
        let key = RedisIntegration.uniqueKey("with-lock")
        let result = try await client.withLock(key, expiresInMilliseconds: 30_000) { 42 }
        #expect(result == 42)
        #expect(try await client.getBytes(key) == Lookup<[UInt8]>.notFound)

        guard case .acquired(let held) = try await client.acquireLock(key, expiresInMilliseconds: 30_000) else {
            Issue.record("expected to acquire the lock")
            await client.shutdown()
            return
        }
        await #expect(throws: RedisError.lockNotAcquired) {
            try await client.withLock(key, expiresInMilliseconds: 30_000) { 1 }
        }
        #expect(try await held.release())
        _ = try await client.delete([key])
        await client.shutdown()
    }
}
