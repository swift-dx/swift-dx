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

// A single-value Decoder over one column cell, used when the keyed
// container's decode<T> reaches a target it does not natively recognise —
// chiefly a RawRepresentable enum field, whose synthesized decoder reads
// its RawValue through a single-value container. Every decode call forwards
// to the originating keyed container's typed decode for the same key, so
// the value is read through the one validated code path with no duplicated
// column-handling logic. Keyed and unkeyed nested containers are rejected:
// a result row column holds a single value, not a sub-structure.
struct ClickHouseColumnValueDecoder<ParentKey: CodingKey>: Decoder {

    let container: ClickHouseColumnarKeyedDecodingContainer<ParentKey>
    let key: ParentKey
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] = [:]

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        ClickHouseColumnValueContainer(container: container, key: key, codingPath: codingPath)
    }

    func container<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        throw DecodingError.dataCorrupted(.init(
            codingPath: codingPath,
            debugDescription: "A result column holds a single value; nested keyed containers are not supported."
        ))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.dataCorrupted(.init(
            codingPath: codingPath,
            debugDescription: "A result column holds a single value; nested unkeyed containers are not supported."
        ))
    }
}

struct ClickHouseColumnValueContainer<ParentKey: CodingKey>: SingleValueDecodingContainer {

    let container: ClickHouseColumnarKeyedDecodingContainer<ParentKey>
    let key: ParentKey
    var codingPath: [CodingKey]

    func decodeNil() -> Bool {
        (try? container.decodeNil(forKey: key)) ?? false
    }

    func decode(_ type: Bool.Type) throws -> Bool { try container.decode(Bool.self, forKey: key) }
    func decode(_ type: String.Type) throws -> String { try container.decode(String.self, forKey: key) }
    func decode(_ type: Double.Type) throws -> Double { try container.decode(Double.self, forKey: key) }
    func decode(_ type: Float.Type) throws -> Float { try container.decode(Float.self, forKey: key) }
    func decode(_ type: Int.Type) throws -> Int { try container.decode(Int.self, forKey: key) }
    func decode(_ type: Int8.Type) throws -> Int8 { try container.decode(Int8.self, forKey: key) }
    func decode(_ type: Int16.Type) throws -> Int16 { try container.decode(Int16.self, forKey: key) }
    func decode(_ type: Int32.Type) throws -> Int32 { try container.decode(Int32.self, forKey: key) }
    func decode(_ type: Int64.Type) throws -> Int64 { try container.decode(Int64.self, forKey: key) }
    func decode(_ type: UInt.Type) throws -> UInt { try container.decode(UInt.self, forKey: key) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try container.decode(UInt8.self, forKey: key) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try container.decode(UInt16.self, forKey: key) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try container.decode(UInt32.self, forKey: key) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try container.decode(UInt64.self, forKey: key) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try container.decode(T.self, forKey: key)
    }
}
