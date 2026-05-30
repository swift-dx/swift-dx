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

    public func database(_ index: RedisDatabaseIndex) -> RedisDatabaseView {
        RedisDatabaseView(client: self, database: index)
    }

    public func swapDatabase(_ first: RedisDatabaseIndex, with second: RedisDatabaseIndex) async throws(RedisError) {
        _ = try await send(.swapDatabase(first.value, second.value), database: defaultDatabase)
    }

    public func flushDatabase(_ mode: RedisFlushMode) async throws(RedisError) {
        try await flushDatabase(mode, database: defaultDatabase)
    }

    public func flushAllDatabases(_ mode: RedisFlushMode) async throws(RedisError) {
        _ = try await send(.flushAll(mode), database: defaultDatabase)
    }

    func flushDatabase(_ mode: RedisFlushMode, database: RedisDatabaseIndex) async throws(RedisError) {
        _ = try await send(.flushDatabase(mode), database: database)
    }
}
