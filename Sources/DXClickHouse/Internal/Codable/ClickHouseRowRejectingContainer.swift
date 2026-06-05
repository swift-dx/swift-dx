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
struct ClickHouseRowRejectingContainer: SingleValueEncodingContainer, UnkeyedEncodingContainer {

    var codingPath: [CodingKey]
    var count: Int = 0

    mutating func encodeNil() throws { throw rejection() }
    mutating func encode<T: Encodable>(_ value: T) throws { throw rejection() }
    mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        KeyedEncodingContainer(ClickHouseRowRejectingKeyedContainer<NestedKey>(codingPath: codingPath))
    }
    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer { self }
    mutating func superEncoder() -> Encoder { ClickHouseRowRejectingEncoder(codingPath: codingPath) }

    private func rejection() -> ClickHouseError {
        .protocolError(
            stage: "encoder.row",
            message: "ClickHouseRowEncoder requires each row to be a keyed container (struct/class). Unkeyed or single-value containers at the row level are not supported."
        )
    }
}

struct ClickHouseRowRejectingKeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {

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
        KeyedEncodingContainer(ClickHouseRowRejectingKeyedContainer<NestedKey>(codingPath: codingPath + [key]))
    }
    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        ClickHouseRowRejectingContainer(codingPath: codingPath + [key])
    }
    mutating func superEncoder() -> Encoder { ClickHouseRowRejectingEncoder(codingPath: codingPath) }
    mutating func superEncoder(forKey key: Key) -> Encoder { ClickHouseRowRejectingEncoder(codingPath: codingPath + [key]) }

    private func rejection() -> ClickHouseError {
        let path = codingPath.map { $0.stringValue }.joined(separator: ".")
        return .protocolError(
            stage: "encoder.nested",
            message: "field '\(path)' encodes as a nested struct, which the insert encoder does not map to a column. Insert a composite column (Tuple, Nested) as an explicit ClickHouseTuple or ClickHouseArrayOfTuple value; every other field of the row must be a flat scalar, array, or map."
        )
    }
}

struct ClickHouseRowRejectingEncoder: Encoder {

    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> where Key: CodingKey {
        KeyedEncodingContainer(ClickHouseRowRejectingKeyedContainer<Key>(codingPath: codingPath))
    }
    func unkeyedContainer() -> UnkeyedEncodingContainer { ClickHouseRowRejectingContainer(codingPath: codingPath) }
    func singleValueContainer() -> SingleValueEncodingContainer { ClickHouseRowRejectingContainer(codingPath: codingPath) }
}
