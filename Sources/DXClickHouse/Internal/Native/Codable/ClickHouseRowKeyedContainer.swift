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
// ClickHouseRowColumnStorage.
struct ClickHouseRowKeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {

    let storage: ClickHouseRowColumnStorage
    let keyEncodingStrategy: ClickHouseKeyEncodingStrategy
    // Identity short-circuit: when the strategy is `.useDefaultKeys`,
    // `apply(to:)` returns its input unchanged, so every per-field call
    // pays for a function call + enum dispatch + COW retain of the
    // returned String. Hoist the decision out of the hot path: a single
    // Bool branch per call replaces the function dispatch.
    let isIdentityStrategy: Bool
    var codingPath: [CodingKey]

    init(
        storage: ClickHouseRowColumnStorage,
        keyEncodingStrategy: ClickHouseKeyEncodingStrategy,
        codingPath: [CodingKey]
    ) {
        self.storage = storage
        self.keyEncodingStrategy = keyEncodingStrategy
        switch keyEncodingStrategy {
        case .useDefaultKeys: self.isIdentityStrategy = true
        case .convertToSnakeCase: self.isIdentityStrategy = false
        }
        self.codingPath = codingPath
    }

    @inline(__always)
    private func columnName(for key: Key) -> String {
        if isIdentityStrategy { return key.stringValue }
        return keyEncodingStrategy.apply(to: key.stringValue)
    }

    mutating func encodeNil(forKey key: Key) throws {
        // A bare `encodeNil` (rather than `encodeIfPresent(nil)`) on
        // a key the encoder hasn't seen before is ambiguous — the
        // type system gives us no hint about what the column should
        // be. Reject loudly. In practice, Codable's auto-generated
        // encoders for Optional<T> route through encodeIfPresent
        // (the typed overloads below), so this path is usually
        // unreachable for well-formed Encodable types.
        throw ClickHouseError.rowEncoderUnsupportedType(
            swiftTypeDescription: "untyped-nil",
            columnName: key.stringValue,
            message: "encodeNil(forKey:) was called on column '\(key.stringValue)' but the column's type is undetermined. The Codable type should encode Optional fields via encodeIfPresent so the encoder can establish a Nullable column type from the wrapped Optional."
        )
    }

    // The encodeIfPresent overrides are the heart of Optional →
    // Nullable. Codable's auto-generated `encode(to:)` for an
    // Optional<T> field calls `encodeIfPresent(value, forKey: key)`.
    // The DEFAULT impl on KeyedEncodingContainerProtocol is "if
    // non-nil, call encode(value, forKey:); if nil, do nothing".
    // The "do nothing" branch silently drops the column for that
    // row — which means columns whose first row has nil never
    // get registered, and the data is silently lost.
    //
    // By overriding ALL primitive overloads, we route both nil and
    // non-nil cases into nullable accumulators. The resulting column
    // is Nullable(T) on the wire even if the value is always
    // present. That's the trade-off: a small wire overhead in
    // exchange for not losing data for a `let foo: T?` field.
    mutating func encodeIfPresent(_ value: Bool?, forKey key: Key) throws {
        try storage.appendNullableBool(ClickHouseNullable(value), forColumn: columnName(for: key))
    }

    mutating func encodeIfPresent(_ value: String?, forKey key: Key) throws {
        try storage.appendNullableString(ClickHouseNullable(value), forColumn: columnName(for: key))
    }

    mutating func encodeIfPresent(_ value: Double?, forKey key: Key) throws {
        try storage.appendNullableDouble(ClickHouseNullable(value), forColumn: columnName(for: key))
    }

    mutating func encodeIfPresent(_ value: Float?, forKey key: Key) throws {
        try storage.appendNullableFloat(ClickHouseNullable(value), forColumn: columnName(for: key))
    }

    mutating func encodeIfPresent(_ value: Int8?, forKey key: Key) throws {
        try storage.appendNullableInt8(ClickHouseNullable(value), forColumn: columnName(for: key))
    }

    mutating func encodeIfPresent(_ value: Int16?, forKey key: Key) throws {
        try storage.appendNullableInt16(ClickHouseNullable(value), forColumn: columnName(for: key))
    }

    mutating func encodeIfPresent(_ value: Int32?, forKey key: Key) throws {
        try storage.appendNullableInt32(ClickHouseNullable(value), forColumn: columnName(for: key))
    }

    mutating func encodeIfPresent(_ value: Int64?, forKey key: Key) throws {
        try storage.appendNullableInt64(ClickHouseNullable(value), forColumn: columnName(for: key))
    }

    mutating func encodeIfPresent(_ value: UInt8?, forKey key: Key) throws {
        try storage.appendNullableUInt8(ClickHouseNullable(value), forColumn: columnName(for: key))
    }

    mutating func encodeIfPresent(_ value: UInt16?, forKey key: Key) throws {
        try storage.appendNullableUInt16(ClickHouseNullable(value), forColumn: columnName(for: key))
    }

    mutating func encodeIfPresent(_ value: UInt32?, forKey key: Key) throws {
        try storage.appendNullableUInt32(ClickHouseNullable(value), forColumn: columnName(for: key))
    }

    mutating func encodeIfPresent(_ value: UInt64?, forKey key: Key) throws {
        try storage.appendNullableUInt64(ClickHouseNullable(value), forColumn: columnName(for: key))
    }

    mutating func encode(_ value: Bool, forKey key: Key) throws {
        try storage.appendBool(value, forColumn: columnName(for: key))
    }

    mutating func encode(_ value: String, forKey key: Key) throws {
        try storage.appendString(value, forColumn: columnName(for: key))
    }

    mutating func encode(_ value: Double, forKey key: Key) throws {
        try storage.appendDouble(value, forColumn: columnName(for: key))
    }

    mutating func encode(_ value: Float, forKey key: Key) throws {
        try storage.appendFloat(value, forColumn: columnName(for: key))
    }

    mutating func encode(_ value: Int, forKey key: Key) throws {
        throw ClickHouseError.rowEncoderUnsupportedType(
            swiftTypeDescription: "Int",
            columnName: key.stringValue,
            message: "Swift `Int` is platform-dependent (32-bit on 32-bit hosts, 64-bit on 64-bit hosts). Use a fixed-width alternative (Int32, Int64) so the column type is unambiguous."
        )
    }

    mutating func encode(_ value: Int8, forKey key: Key) throws {
        try storage.appendInt8(value, forColumn: columnName(for: key))
    }

    mutating func encode(_ value: Int16, forKey key: Key) throws {
        try storage.appendInt16(value, forColumn: columnName(for: key))
    }

    mutating func encode(_ value: Int32, forKey key: Key) throws {
        try storage.appendInt32(value, forColumn: columnName(for: key))
    }

    mutating func encode(_ value: Int64, forKey key: Key) throws {
        try storage.appendInt64(value, forColumn: columnName(for: key))
    }

    mutating func encode(_ value: UInt, forKey key: Key) throws {
        throw ClickHouseError.rowEncoderUnsupportedType(
            swiftTypeDescription: "UInt",
            columnName: key.stringValue,
            message: "Swift `UInt` is platform-dependent. Use a fixed-width alternative (UInt32, UInt64)."
        )
    }

    mutating func encode(_ value: UInt8, forKey key: Key) throws {
        try storage.appendUInt8(value, forColumn: columnName(for: key))
    }

    mutating func encode(_ value: UInt16, forKey key: Key) throws {
        try storage.appendUInt16(value, forColumn: columnName(for: key))
    }

    mutating func encode(_ value: UInt32, forKey key: Key) throws {
        try storage.appendUInt32(value, forColumn: columnName(for: key))
    }

    mutating func encode(_ value: UInt64, forKey key: Key) throws {
        try storage.appendUInt64(value, forColumn: columnName(for: key))
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        if try tryEncodeSpecialType(value: value, key: key) { return }
        throw ClickHouseError.rowEncoderUnsupportedType(
            swiftTypeDescription: String(describing: type(of: value)),
            columnName: key.stringValue,
            message: "ClickHouseRowEncoder supports primitive Codable types, Date, UUID, and [String: String] directly. Other dictionaries, arrays, nested structs, etc. require explicit support in later phases."
        )
    }

    private mutating func tryEncodeSpecialType<T: Encodable>(value: T, key: Key) throws -> Bool {
        if let date = value as? Date {
            try storage.appendDateTime(date, forColumn: columnName(for: key))
            return true
        }
        return try tryEncodeUUIDOrMap(value: value, key: key)
    }

    private mutating func tryEncodeUUIDOrMap<T: Encodable>(value: T, key: Key) throws -> Bool {
        if let uuid = value as? UUID {
            try storage.appendUUID(uuid, forColumn: columnName(for: key))
            return true
        }
        if let map = value as? [String: String] {
            try storage.appendMapStringString(map, forColumn: columnName(for: key))
            return true
        }
        return false
    }

    mutating func encodeIfPresent<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if try tryEncodeIfPresentSpecialOptional(value: value, key: key) { return }
        guard let value else {
            throw ClickHouseError.rowEncoderUnsupportedType(
                swiftTypeDescription: "Optional<\(T.self)>",
                columnName: key.stringValue,
                message: "ClickHouseRowEncoder supports Optional only for primitive numeric types, Bool, String, Float, Double, Date, and UUID. Optional<\(T.self)> has no corresponding Nullable column type on the wire — make this field non-Optional or pick a supported alternative."
            )
        }
        try encode(value, forKey: key)
    }

    private mutating func tryEncodeIfPresentSpecialOptional<T: Encodable>(value: T?, key: Key) throws -> Bool {
        if T.self == Date.self {
            try storage.appendNullableDateTime(ClickHouseNullable(value as? Date), forColumn: columnName(for: key))
            return true
        }
        if T.self == UUID.self {
            try storage.appendNullableUUID(ClickHouseNullable(value as? UUID), forColumn: columnName(for: key))
            return true
        }
        return false
    }

    mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        let rejecting = ClickHouseRowRejectingKeyedContainer<NestedKey>(
            codingPath: codingPath + [key],
            message: "Nested keyed containers are not supported. Each row must be a flat struct of supported primitives."
        )
        return KeyedEncodingContainer(rejecting)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        ClickHouseRowRejectingContainer(
            codingPath: codingPath + [key],
            message: "Nested unkeyed containers are not supported. Each row must be a flat struct of supported primitives."
        )
    }

    mutating func superEncoder() -> Encoder {
        ClickHouseRowRejectingEncoder(codingPath: codingPath, message: "superEncoder is not supported by ClickHouseRowEncoder.")
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        ClickHouseRowRejectingEncoder(codingPath: codingPath + [key], message: "superEncoder(forKey:) is not supported by ClickHouseRowEncoder.")
    }

}
