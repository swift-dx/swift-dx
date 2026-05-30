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

import Foundation

// Rejects every encode call by throwing a typed error. Returned from the
// encoder facade when the caller asks for an unkeyed or single-value
// container at the row level: each row must be a keyed struct, not an
// array or scalar.
struct RawClickHouseRowRejectingContainer: SingleValueEncodingContainer, UnkeyedEncodingContainer {

    var codingPath: [CodingKey]
    var count: Int = 0

    mutating func encodeNil() throws { throw rejection() }
    mutating func encode<T: Encodable>(_ value: T) throws { throw rejection() }
    mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        KeyedEncodingContainer(RawClickHouseRowRejectingKeyedContainer<NestedKey>(codingPath: codingPath))
    }
    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer { self }
    mutating func superEncoder() -> Encoder { RawClickHouseRowRejectingEncoder(codingPath: codingPath) }

    private func rejection() -> RawClickHouseError {
        .protocolError(
            stage: "encoder.row",
            message: "RawClickHouseRowEncoder requires each row to be a keyed container (struct/class). Unkeyed or single-value containers at the row level are not supported."
        )
    }
}

struct RawClickHouseRowRejectingKeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {

    var codingPath: [CodingKey]

    mutating func encodeNil(forKey key: Key) throws { throw rejection() }
    mutating func encode(_ value: Bool, forKey key: Key) throws { throw rejection() }
    mutating func encode(_ value: String, forKey key: Key) throws { throw rejection() }
    mutating func encode(_ value: Double, forKey key: Key) throws { throw rejection() }
    mutating func encode(_ value: Float, forKey key: Key) throws { throw rejection() }
    mutating func encode(_ value: Int, forKey key: Key) throws { throw rejection() }
    mutating func encode(_ value: Int8, forKey key: Key) throws { throw rejection() }
    mutating func encode(_ value: Int16, forKey key: Key) throws { throw rejection() }
    mutating func encode(_ value: Int32, forKey key: Key) throws { throw rejection() }
    mutating func encode(_ value: Int64, forKey key: Key) throws { throw rejection() }
    mutating func encode(_ value: UInt, forKey key: Key) throws { throw rejection() }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { throw rejection() }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { throw rejection() }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { throw rejection() }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { throw rejection() }
    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws { throw rejection() }
    mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        KeyedEncodingContainer(RawClickHouseRowRejectingKeyedContainer<NestedKey>(codingPath: codingPath + [key]))
    }
    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        RawClickHouseRowRejectingContainer(codingPath: codingPath + [key])
    }
    mutating func superEncoder() -> Encoder { RawClickHouseRowRejectingEncoder(codingPath: codingPath) }
    mutating func superEncoder(forKey key: Key) -> Encoder { RawClickHouseRowRejectingEncoder(codingPath: codingPath + [key]) }

    private func rejection() -> RawClickHouseError {
        .protocolError(
            stage: "encoder.nested",
            message: "Nested containers are not supported. Each row must be a flat keyed struct of supported scalars."
        )
    }
}

struct RawClickHouseRowRejectingEncoder: Encoder {

    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> where Key: CodingKey {
        KeyedEncodingContainer(RawClickHouseRowRejectingKeyedContainer<Key>(codingPath: codingPath))
    }
    func unkeyedContainer() -> UnkeyedEncodingContainer { RawClickHouseRowRejectingContainer(codingPath: codingPath) }
    func singleValueContainer() -> SingleValueEncodingContainer { RawClickHouseRowRejectingContainer(codingPath: codingPath) }
}
