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

/// Server and pool administration: selecting and flushing databases, warming and
/// inspecting the connection pool, liveness, and shutdown.
///
/// `RedisClient` conforms to this. Depend on `some RedisAdmin` when a type only
/// administers the client or server rather than reading and writing data.
public protocol RedisAdmin: Sendable {

    func database(_ index: RedisDatabaseIndex) -> RedisDatabaseView
    func swapDatabase(_ first: RedisDatabaseIndex, with second: RedisDatabaseIndex) async throws(RedisError)
    func flushDatabase(_ mode: RedisFlushMode) async throws(RedisError)
    func flushAllDatabases(_ mode: RedisFlushMode) async throws(RedisError)

    func warmUp(connections: Int) async throws(RedisError)
    func ping() async throws(RedisError)
    func poolStats() async -> RedisPoolStats
    func shutdown() async
}
