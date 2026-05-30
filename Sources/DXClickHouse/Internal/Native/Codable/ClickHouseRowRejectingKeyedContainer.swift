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

// Defensive KeyedEncodingContainer stand-in for Phase-1-unsupported
// nested keyed paths.
struct ClickHouseRowRejectingKeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {

    var codingPath: [CodingKey]
    let message: String

    private func reject() throws {
        throw ClickHouseError.rowEncoderUnsupportedType(
            swiftTypeDescription: "nested",
            columnName: "",
            message: message
        )
    }

    mutating func encodeNil(forKey key: Key) throws { try reject() }
    mutating func encode(_ value: Bool, forKey key: Key) throws { try reject() }
    mutating func encode(_ value: String, forKey key: Key) throws { try reject() }
    mutating func encode(_ value: Double, forKey key: Key) throws { try reject() }
    mutating func encode(_ value: Float, forKey key: Key) throws { try reject() }
    mutating func encode(_ value: Int, forKey key: Key) throws { try reject() }
    mutating func encode(_ value: Int8, forKey key: Key) throws { try reject() }
    mutating func encode(_ value: Int16, forKey key: Key) throws { try reject() }
    mutating func encode(_ value: Int32, forKey key: Key) throws { try reject() }
    mutating func encode(_ value: Int64, forKey key: Key) throws { try reject() }
    mutating func encode(_ value: UInt, forKey key: Key) throws { try reject() }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { try reject() }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { try reject() }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { try reject() }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { try reject() }
    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws { try reject() }

    mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        return KeyedEncodingContainer(ClickHouseRowRejectingKeyedContainer<NestedKey>(codingPath: codingPath + [key], message: message))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        ClickHouseRowRejectingContainer(codingPath: codingPath + [key], message: message)
    }

    mutating func superEncoder() -> Encoder {
        ClickHouseRowRejectingEncoder(codingPath: codingPath, message: message)
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        ClickHouseRowRejectingEncoder(codingPath: codingPath + [key], message: message)
    }

}
