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

// A held distributed lock. `release` and `extend` are token-checked on the server
// (a holder only ever affects its own lock), so a lock that expired and was taken
// by another holder is never released or extended by the previous holder.
public struct RedisLock: Sendable {

    public let key: RedisKey
    public let token: RedisLockToken
    let client: RedisClient
    let database: RedisDatabaseIndex

    init(key: RedisKey, token: RedisLockToken, client: RedisClient, database: RedisDatabaseIndex) {
        self.key = key
        self.token = token
        self.client = client
        self.database = database
    }

    @discardableResult
    public func release() async throws(RedisError) -> Bool {
        try await client.releaseLock(key, token: token, database: database)
    }

    @discardableResult
    public func extend(byMilliseconds milliseconds: Int) async throws(RedisError) -> Bool {
        try await client.extendLock(key, token: token, milliseconds: milliseconds, database: database)
    }
}
