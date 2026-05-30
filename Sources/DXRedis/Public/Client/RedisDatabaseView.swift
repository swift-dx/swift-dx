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

// A view of a RedisClient bound to one logical database. Every operation
// issued through the view targets that database: when a pooled connection is
// currently selected onto a different database the client prepends a single
// pipelined SELECT, so cross-database work costs at most one extra round of
// bytes on the first command after a switch and zero thereafter.
public struct RedisDatabaseView: Sendable {

    let client: RedisClient
    let database: RedisDatabaseIndex

    init(client: RedisClient, database: RedisDatabaseIndex) {
        self.client = client
        self.database = database
    }

    public func send(_ command: RedisCommand) async throws(RedisError) -> RESPValue {
        try await client.send(command, database: database)
    }

    public func pipeline(_ commands: [RedisCommand]) async throws(RedisError) -> [RESPValue] {
        try await client.pipeline(commands, database: database)
    }

    public func pipelineExpectingSuccess(_ commands: [RedisCommand]) async throws(RedisError) {
        try await client.pipelineExpectingSuccess(commands, database: database)
    }

    public func set(_ key: RedisKey, to value: [UInt8]) async throws(RedisError) {
        try await client.setValue(key, value: value, database: database)
    }

    public func set(_ key: RedisKey, to value: ByteBuffer) async throws(RedisError) {
        try await client.setValue(key, value: Array(value.readableBytesView), database: database)
    }

    public func set(_ key: RedisKey, to value: String) async throws(RedisError) {
        try await client.setValue(key, value: Array(value.utf8), database: database)
    }

    public func set<Value: Encodable & Sendable>(_ key: RedisKey, toJSON value: Value) async throws(RedisError) {
        try await client.setJSON(key, value: value, database: database)
    }

    public func get(_ key: RedisKey) async throws(RedisError) -> Lookup<ByteBuffer> {
        try await client.getBuffer(key, database: database)
    }

    public func getBytes(_ key: RedisKey) async throws(RedisError) -> Lookup<[UInt8]> {
        try await client.execute(.get(key), on: database).bytesLookup()
    }

    public func getString(_ key: RedisKey) async throws(RedisError) -> Lookup<String> {
        try await client.execute(.get(key), on: database).stringLookup()
    }

    public func get<Value: Decodable & Sendable>(_ key: RedisKey, asJSON type: Value.Type) async throws(RedisError) -> Lookup<Value> {
        try await client.getJSON(key, as: type, database: database)
    }

    public func get(_ keys: [RedisKey]) async throws(RedisError) -> [Lookup<ByteBuffer>] {
        try await client.multiGet(keys, database: database)
    }

    public func delete(_ keys: [RedisKey]) async throws(RedisError) -> Int {
        try await client.deleteKeys(keys, database: database)
    }

    public func existsCount(_ keys: [RedisKey]) async throws(RedisError) -> Int {
        try await client.existsCount(keys, database: database)
    }

    public func set(_ pairs: [RedisKeyValuePair]) async throws(RedisError) {
        try await client.multiSet(pairs, database: database)
    }

    public func setPipelined(_ pairs: [RedisKeyValuePair]) async throws(RedisError) {
        try await client.multiSetPipelined(pairs, database: database)
    }

    public func flush(_ mode: RedisFlushMode) async throws(RedisError) {
        try await client.flushDatabase(mode, database: database)
    }
}
