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

// Defensive Unkeyed/SingleValue stand-in. Throws on every operation
// to ensure unsupported Phase-1 paths fail loudly rather than
// silently dropping data.
struct ClickHouseRowRejectingContainer: UnkeyedEncodingContainer, SingleValueEncodingContainer {

    var codingPath: [CodingKey]
    let message: String

    var count: Int { 0 }

    private func reject(_ name: String) throws {
        throw ClickHouseError.rowEncoderUnsupportedType(
            swiftTypeDescription: name,
            columnName: "",
            message: message
        )
    }

    mutating func encodeNil() throws { try reject("nil") }
    mutating func encode(_ value: Bool) throws { try reject("Bool") }
    mutating func encode(_ value: String) throws { try reject("String") }
    mutating func encode(_ value: Double) throws { try reject("Double") }
    mutating func encode(_ value: Float) throws { try reject("Float") }
    mutating func encode(_ value: Int) throws { try reject("Int") }
    mutating func encode(_ value: Int8) throws { try reject("Int8") }
    mutating func encode(_ value: Int16) throws { try reject("Int16") }
    mutating func encode(_ value: Int32) throws { try reject("Int32") }
    mutating func encode(_ value: Int64) throws { try reject("Int64") }
    mutating func encode(_ value: UInt) throws { try reject("UInt") }
    mutating func encode(_ value: UInt8) throws { try reject("UInt8") }
    mutating func encode(_ value: UInt16) throws { try reject("UInt16") }
    mutating func encode(_ value: UInt32) throws { try reject("UInt32") }
    mutating func encode(_ value: UInt64) throws { try reject("UInt64") }
    mutating func encode<T: Encodable>(_ value: T) throws { try reject(String(describing: type(of: value))) }

    mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        let rejecting = ClickHouseRowRejectingKeyedContainer<NestedKey>(
            codingPath: codingPath, message: message
        )
        return KeyedEncodingContainer(rejecting)
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        self
    }

    mutating func superEncoder() -> Encoder {
        ClickHouseRowRejectingEncoder(codingPath: codingPath, message: message)
    }

}
