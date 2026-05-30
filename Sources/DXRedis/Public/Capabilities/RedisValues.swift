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

/// Reading and writing key values: the everyday `GET`/`SET` surface, batch and
/// pipelined multi-key variants, conditional writes, and JSON convenience.
///
/// `RedisClient` conforms to this. Depend on `some RedisValues` when a type only
/// needs to read and write values, not manage expiry, run scripts, or administer
/// the server.
public protocol RedisValues: Sendable {

    func set(_ key: RedisKey, to value: [UInt8]) async throws(RedisError)
    func set(_ key: RedisKey, to value: ByteBuffer) async throws(RedisError)
    func set(_ key: RedisKey, to value: String) async throws(RedisError)
    func set<Value: Encodable & Sendable>(_ key: RedisKey, toJSON value: Value) async throws(RedisError)
    func set(_ key: RedisKey, to value: [UInt8], condition: RedisSetCondition, expiration: RedisExpiration) async throws(RedisError) -> Bool
    func set(_ key: RedisKey, to value: String, condition: RedisSetCondition, expiration: RedisExpiration) async throws(RedisError) -> Bool
    func setIfAbsent(_ key: RedisKey, to value: [UInt8], expiration: RedisExpiration) async throws(RedisError) -> Bool

    func get(_ key: RedisKey) async throws(RedisError) -> Lookup<ByteBuffer>
    func getBytes(_ key: RedisKey) async throws(RedisError) -> Lookup<[UInt8]>
    func getString(_ key: RedisKey) async throws(RedisError) -> Lookup<String>
    func get<Value: Decodable & Sendable>(_ key: RedisKey, asJSON type: Value.Type) async throws(RedisError) -> Lookup<Value>

    func delete(_ keys: [RedisKey]) async throws(RedisError) -> Int
    func exists(_ key: RedisKey) async throws(RedisError) -> Bool
    func existsCount(_ keys: [RedisKey]) async throws(RedisError) -> Int

    func set(_ pairs: [RedisKeyValuePair]) async throws(RedisError)
    func setPipelined(_ pairs: [RedisKeyValuePair]) async throws(RedisError)
    func get(_ keys: [RedisKey]) async throws(RedisError) -> [Lookup<ByteBuffer>]
    func getPipelined(_ keys: [RedisKey]) async throws(RedisError) -> [Lookup<ByteBuffer>]
}
