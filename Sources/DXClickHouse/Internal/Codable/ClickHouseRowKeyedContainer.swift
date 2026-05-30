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

// KeyedEncodingContainer that routes Codable's per-field
// `encode(_, forKey:)` calls into the typed accumulators on
// ClickHouseRowEncoderStorage.
struct ClickHouseRowKeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {

    let storage: ClickHouseRowEncoderStorage
    var codingPath: [CodingKey]

    init(storage: ClickHouseRowEncoderStorage, codingPath: [CodingKey]) {
        self.storage = storage
        self.codingPath = codingPath
    }

    mutating func encodeNil(forKey key: Key) throws {
        // Bare `encodeNil` (rather than `encodeIfPresent(nil)`) on a key
        // the encoder has never seen is structurally ambiguous: no type
        // information is available, so the encoder cannot register a
        // Nullable(T) column. Codable's auto-generated encoders for
        // Optional<T> route through `encodeIfPresent`, which IS routed
        // below into a typed Nullable accumulator.
        throw ClickHouseError.protocolError(
            stage: "encoder.encodeNil",
            message: "encodeNil(forKey:) is not supported for column '\(key.stringValue)'; encode Optional fields via encodeIfPresent so the column's type is known."
        )
    }

    mutating func encodeIfPresent(_ value: Bool?, forKey key: Key) throws {
        try storage.appendNullableBool(toNullable(value), forColumn: key.stringValue)
    }

    mutating func encodeIfPresent(_ value: String?, forKey key: Key) throws {
        try storage.appendNullableString(toNullable(value), forColumn: key.stringValue)
    }

    mutating func encodeIfPresent(_ value: Double?, forKey key: Key) throws {
        try storage.appendNullableDouble(toNullable(value), forColumn: key.stringValue)
    }

    mutating func encodeIfPresent(_ value: Float?, forKey key: Key) throws {
        try storage.appendNullableFloat(toNullable(value), forColumn: key.stringValue)
    }

    mutating func encodeIfPresent(_ value: Int8?, forKey key: Key) throws {
        try storage.appendNullableInt8(toNullable(value), forColumn: key.stringValue)
    }

    mutating func encodeIfPresent(_ value: Int16?, forKey key: Key) throws {
        try storage.appendNullableInt16(toNullable(value), forColumn: key.stringValue)
    }

    mutating func encodeIfPresent(_ value: Int32?, forKey key: Key) throws {
        try storage.appendNullableInt32(toNullable(value), forColumn: key.stringValue)
    }

    mutating func encodeIfPresent(_ value: Int64?, forKey key: Key) throws {
        try storage.appendNullableInt64(toNullable(value), forColumn: key.stringValue)
    }

    mutating func encodeIfPresent(_ value: UInt8?, forKey key: Key) throws {
        try storage.appendNullableUInt8(toNullable(value), forColumn: key.stringValue)
    }

    mutating func encodeIfPresent(_ value: UInt16?, forKey key: Key) throws {
        try storage.appendNullableUInt16(toNullable(value), forColumn: key.stringValue)
    }

    mutating func encodeIfPresent(_ value: UInt32?, forKey key: Key) throws {
        try storage.appendNullableUInt32(toNullable(value), forColumn: key.stringValue)
    }

    mutating func encodeIfPresent(_ value: UInt64?, forKey key: Key) throws {
        try storage.appendNullableUInt64(toNullable(value), forColumn: key.stringValue)
    }

    mutating func encode(_ value: Bool, forKey key: Key) throws {
        try storage.appendBool(value, forColumn: key.stringValue)
    }

    mutating func encode(_ value: String, forKey key: Key) throws {
        try storage.appendString(value, forColumn: key.stringValue)
    }

    mutating func encode(_ value: Double, forKey key: Key) throws {
        try storage.appendDouble(value, forColumn: key.stringValue)
    }

    mutating func encode(_ value: Float, forKey key: Key) throws {
        try storage.appendFloat(value, forColumn: key.stringValue)
    }

    mutating func encode(_ value: Int, forKey key: Key) throws {
        throw ClickHouseError.protocolError(
            stage: "encoder.encode",
            message: "Swift `Int` is platform-dependent. Column '\(key.stringValue)' must use a fixed-width alternative (Int32, Int64)."
        )
    }

    mutating func encode(_ value: Int8, forKey key: Key) throws {
        try storage.appendInt8(value, forColumn: key.stringValue)
    }

    mutating func encode(_ value: Int16, forKey key: Key) throws {
        try storage.appendInt16(value, forColumn: key.stringValue)
    }

    mutating func encode(_ value: Int32, forKey key: Key) throws {
        try storage.appendInt32(value, forColumn: key.stringValue)
    }

    mutating func encode(_ value: Int64, forKey key: Key) throws {
        try storage.appendInt64(value, forColumn: key.stringValue)
    }

    mutating func encode(_ value: UInt, forKey key: Key) throws {
        throw ClickHouseError.protocolError(
            stage: "encoder.encode",
            message: "Swift `UInt` is platform-dependent. Column '\(key.stringValue)' must use a fixed-width alternative (UInt32, UInt64)."
        )
    }

    mutating func encode(_ value: UInt8, forKey key: Key) throws {
        try storage.appendUInt8(value, forColumn: key.stringValue)
    }

    mutating func encode(_ value: UInt16, forKey key: Key) throws {
        try storage.appendUInt16(value, forColumn: key.stringValue)
    }

    mutating func encode(_ value: UInt32, forKey key: Key) throws {
        try storage.appendUInt32(value, forColumn: key.stringValue)
    }

    mutating func encode(_ value: UInt64, forKey key: Key) throws {
        try storage.appendUInt64(value, forColumn: key.stringValue)
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        if let date = value as? Date {
            try storage.appendDateTime(date, forColumn: key.stringValue)
            return
        }
        if let uuid = value as? UUID {
            try storage.appendUUID(uuid, forColumn: key.stringValue)
            return
        }
        throw ClickHouseError.protocolError(
            stage: "encoder.encode",
            message: "column '\(key.stringValue)' has unsupported Swift type \(String(describing: type(of: value))). The raw Codable layer supports primitives, String, Bool, Float, Double, Date, UUID, and their Optional variants."
        )
    }

    mutating func encodeIfPresent<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if try encodeIfDateOrUUIDOptional(value, forKey: key) { return }
        guard let value else {
            throw ClickHouseError.protocolError(
                stage: "encoder.encodeIfPresent",
                message: "column '\(key.stringValue)' has unsupported Optional Swift type \(String(describing: T.self))."
            )
        }
        try encode(value, forKey: key)
    }

    private mutating func encodeIfDateOrUUIDOptional<T: Encodable>(_ value: T?, forKey key: Key) throws -> Bool {
        if T.self == Date.self {
            try storage.appendNullableDateTime(toNullable(value as? Date), forColumn: key.stringValue)
            return true
        }
        if T.self == UUID.self {
            try storage.appendNullableUUID(toNullable(value as? UUID), forColumn: key.stringValue)
            return true
        }
        return false
    }

    mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        KeyedEncodingContainer(ClickHouseRowRejectingKeyedContainer<NestedKey>(codingPath: codingPath + [key]))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        ClickHouseRowRejectingContainer(codingPath: codingPath + [key])
    }

    mutating func superEncoder() -> Encoder {
        ClickHouseRowRejectingEncoder(codingPath: codingPath)
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        ClickHouseRowRejectingEncoder(codingPath: codingPath + [key])
    }

    @inline(__always)
    private func toNullable<Wrapped: Sendable>(_ value: Wrapped?) -> ClickHouseNullable<Wrapped> {
        if let value { return .present(value) }
        return .absent
    }
}
