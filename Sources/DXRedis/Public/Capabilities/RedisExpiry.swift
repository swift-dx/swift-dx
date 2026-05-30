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

/// Key lifetime: setting a time to live, clearing it, and reading how long a key
/// has left.
///
/// `RedisClient` conforms to this. Depend on `some RedisExpiry` when a type only
/// manages key expiry.
public protocol RedisExpiry: Sendable {

    func expire(_ key: RedisKey, seconds: Int) async throws(RedisError) -> Bool
    func expire(_ key: RedisKey, milliseconds: Int) async throws(RedisError) -> Bool
    func persist(_ key: RedisKey) async throws(RedisError) -> Bool
    func timeToLive(_ key: RedisKey) async throws(RedisError) -> RedisTimeToLive
}
