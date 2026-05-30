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

/// Advisory distributed locking built on single-key expiry: acquire a lock for a
/// bounded lease, or run a body while holding one and release it afterward.
///
/// `RedisClient` conforms to this. Depend on `some RedisLocking` when a type only
/// coordinates through locks.
public protocol RedisLocking: Sendable {

    func acquireLock(_ key: RedisKey, expiresInMilliseconds milliseconds: Int) async throws(RedisError) -> RedisLockOutcome
    func withLock<Result>(_ key: RedisKey, expiresInMilliseconds milliseconds: Int, _ body: () async throws -> Result) async throws -> Result
}
