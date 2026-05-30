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
import NIOCore

extension RedisClient {

    public func set(_ key: RedisKey, to value: [UInt8]) async throws(RedisError) {
        try await setValue(key, value: value, database: defaultDatabase)
    }

    public func set(_ key: RedisKey, to value: ByteBuffer) async throws(RedisError) {
        try await setValue(key, value: Array(value.readableBytesView), database: defaultDatabase)
    }

    public func set(_ key: RedisKey, to value: String) async throws(RedisError) {
        try await setValue(key, value: Array(value.utf8), database: defaultDatabase)
    }

    // Zero-copy read: the returned ByteBuffer shares the receive buffer's storage.
    public func get(_ key: RedisKey) async throws(RedisError) -> Lookup<ByteBuffer> {
        try await getBuffer(key, database: defaultDatabase)
    }

    public func getBytes(_ key: RedisKey) async throws(RedisError) -> Lookup<[UInt8]> {
        try await execute(.get(key), on: defaultDatabase).bytesLookup()
    }

    public func getString(_ key: RedisKey) async throws(RedisError) -> Lookup<String> {
        try await execute(.get(key), on: defaultDatabase).stringLookup()
    }

    public func delete(_ keys: [RedisKey]) async throws(RedisError) -> Int {
        try await deleteKeys(keys, database: defaultDatabase)
    }

    public func exists(_ key: RedisKey) async throws(RedisError) -> Bool {
        let count = try await existsCount([key], database: defaultDatabase)
        return count > 0
    }

    public func existsCount(_ keys: [RedisKey]) async throws(RedisError) -> Int {
        try await existsCount(keys, database: defaultDatabase)
    }

    public func set(_ pairs: [RedisKeyValuePair]) async throws(RedisError) {
        try await multiSet(pairs, database: defaultDatabase)
    }

    public func setPipelined(_ pairs: [RedisKeyValuePair]) async throws(RedisError) {
        try await multiSetPipelined(pairs, database: defaultDatabase)
    }

    public func get(_ keys: [RedisKey]) async throws(RedisError) -> [Lookup<ByteBuffer>] {
        try await multiGet(keys, database: defaultDatabase)
    }

    public func getPipelined(_ keys: [RedisKey]) async throws(RedisError) -> [Lookup<ByteBuffer>] {
        try await getPipelined(keys, database: defaultDatabase)
    }

    func setValue(_ key: RedisKey, value: [UInt8], database: RedisDatabaseIndex) async throws(RedisError) {
        _ = try await send(.set(key, value: value), database: database)
    }

    func getBuffer(_ key: RedisKey, database: RedisDatabaseIndex) async throws(RedisError) -> Lookup<ByteBuffer> {
        try await execute(.get(key), on: database).bufferLookup()
    }

    func deleteKeys(_ keys: [RedisKey], database: RedisDatabaseIndex) async throws(RedisError) -> Int {
        guard !keys.isEmpty else { return 0 }
        let value = try await send(.delete(keys), database: database).integerValue()
        return Int(value)
    }

    func existsCount(_ keys: [RedisKey], database: RedisDatabaseIndex) async throws(RedisError) -> Int {
        guard !keys.isEmpty else { return 0 }
        let value = try await send(.exists(keys), database: database).integerValue()
        return Int(value)
    }

    func multiSet(_ pairs: [RedisKeyValuePair], database: RedisDatabaseIndex) async throws(RedisError) {
        guard !pairs.isEmpty else { return }
        try await executeMultiSet(pairs, on: database)
    }

    func multiSetPipelined(_ pairs: [RedisKeyValuePair], database: RedisDatabaseIndex) async throws(RedisError) {
        guard !pairs.isEmpty else { return }
        try await executeSetPipeline(pairs, on: database)
    }

    func getPipelined(_ keys: [RedisKey], database: RedisDatabaseIndex) async throws(RedisError) -> [Lookup<ByteBuffer>] {
        guard !keys.isEmpty else { return [] }
        let replies = try await executeGetPipeline(keys, on: database)
        return try Self.lookups(from: replies)
    }

    func multiGet(_ keys: [RedisKey], database: RedisDatabaseIndex) async throws(RedisError) -> [Lookup<ByteBuffer>] {
        guard !keys.isEmpty else { return [] }
        return try await executeArray(.multiGet(keys), on: database).lookups()
    }

    static func lookups(from elements: [RESPValue]) throws(RedisError) -> [Lookup<ByteBuffer>] {
        var result: [Lookup<ByteBuffer>] = []
        result.reserveCapacity(elements.count)
        for element in elements {
            result.append(try element.bufferLookup())
        }
        return result
    }
}
