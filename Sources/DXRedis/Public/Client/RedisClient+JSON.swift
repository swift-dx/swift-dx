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
import Foundation
import NIOCore

extension RedisClient {

    public func set<Value: Encodable & Sendable>(_ key: RedisKey, toJSON value: Value) async throws(RedisError) {
        try await setJSON(key, value: value, database: defaultDatabase)
    }

    public func get<Value: Decodable & Sendable>(_ key: RedisKey, asJSON type: Value.Type) async throws(RedisError) -> Lookup<Value> {
        try await getJSON(key, as: type, database: defaultDatabase)
    }

    func setJSON<Value: Encodable & Sendable>(_ key: RedisKey, value: Value, database: RedisDatabaseIndex) async throws(RedisError) {
        let bytes = try Self.encodeJSON(value)
        try await setValue(key, value: bytes, database: database)
    }

    func getJSON<Value: Decodable & Sendable>(_ key: RedisKey, as type: Value.Type, database: RedisDatabaseIndex) async throws(RedisError) -> Lookup<Value> {
        let lookup = try await getBuffer(key, database: database)
        return try Self.decodeLookup(lookup, as: type)
    }

    static func encodeJSON<Value: Encodable>(_ value: Value) throws(RedisError) -> [UInt8] {
        do {
            return Array(try JSONEncoder().encode(value))
        } catch {
            throw RedisError.jsonEncodingFailed(typeName: String(describing: Value.self), reason: String(describing: error))
        }
    }

    static func decodeLookup<Value: Decodable>(_ lookup: Lookup<ByteBuffer>, as type: Value.Type) throws(RedisError) -> Lookup<Value> {
        switch lookup {
        case .notFound: .notFound
        case .found(let buffer): .found(try decodeJSON(buffer, as: type))
        }
    }

    static func decodeJSON<Value: Decodable>(_ buffer: ByteBuffer, as type: Value.Type) throws(RedisError) -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: Data(buffer.readableBytesView))
        } catch {
            throw RedisError.jsonDecodingFailed(typeName: String(describing: Value.self), reason: String(describing: error))
        }
    }
}
