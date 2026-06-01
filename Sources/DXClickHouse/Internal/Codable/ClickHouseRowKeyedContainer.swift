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
        if let dateTime64 = value as? ClickHouseDateTime64 {
            try storage.appendDateTime64(dateTime64.ticks, precision: dateTime64.precision, forColumn: key.stringValue)
            return
        }
        if let fixedString = value as? ClickHouseFixedString {
            try storage.appendFixedString(fixedString.bytes, length: fixedString.length, forColumn: key.stringValue)
            return
        }
        if let enum8 = value as? ClickHouseEnum8 {
            try storage.appendEnum8(enum8.value, mapping: enum8.mapping, forColumn: key.stringValue)
            return
        }
        if let enum16 = value as? ClickHouseEnum16 {
            try storage.appendEnum16(enum16.value, mapping: enum16.mapping, forColumn: key.stringValue)
            return
        }
        if let lowCardinality = value as? ClickHouseLowCardinality {
            try storage.appendLowCardinality(lowCardinality.value, inner: lowCardinality.inner, forColumn: key.stringValue)
            return
        }
        if let array = value as? ClickHouseArray {
            try storage.appendArray(array.elements, element: array.element, forColumn: key.stringValue)
            return
        }
        if let tuple = value as? ClickHouseTuple {
            try storage.appendTuple(tuple.values, elements: tuple.elements, forColumn: key.stringValue)
            return
        }
        if let map = value as? ClickHouseMap {
            try storage.appendMap(keys: map.keys, values: map.values, keyElement: map.keyElement, valueElement: map.valueElement, forColumn: key.stringValue)
            return
        }
        if let arrayOfTuple = value as? ClickHouseArrayOfTuple {
            try storage.appendArrayOfTuple(firstValues: arrayOfTuple.firstValues, secondValues: arrayOfTuple.secondValues, firstElement: arrayOfTuple.firstElement, secondElement: arrayOfTuple.secondElement, forColumn: key.stringValue)
            return
        }
        if let date32 = value as? ClickHouseDate32 {
            try storage.appendDate32(date32.days, forColumn: key.stringValue)
            return
        }
        if let bfloat16 = value as? ClickHouseBFloat16 {
            try storage.appendBFloat16(bfloat16.rawBits, forColumn: key.stringValue)
            return
        }
        if let date = value as? ClickHouseDate {
            try storage.appendDate(date.days, forColumn: key.stringValue)
            return
        }
        if let time = value as? ClickHouseTime {
            try storage.appendTime(time.seconds, forColumn: key.stringValue)
            return
        }
        if let time64 = value as? ClickHouseTime64 {
            try storage.appendTime64(time64.ticks, precision: time64.precision, forColumn: key.stringValue)
            return
        }
        if let ipv4 = value as? ClickHouseIPv4 {
            try storage.appendIPv4(ipv4.raw, forColumn: key.stringValue)
            return
        }
        if let ipv6 = value as? ClickHouseIPv6 {
            try storage.appendIPv6(ipv6.bytes, forColumn: key.stringValue)
            return
        }
        if let int128 = value as? ClickHouseInt128 {
            try storage.appendInt128(int128.value, forColumn: key.stringValue)
            return
        }
        if let uint128 = value as? ClickHouseUInt128 {
            try storage.appendUInt128(uint128.value, forColumn: key.stringValue)
            return
        }
        if let int256 = value as? ClickHouseInt256 {
            try storage.appendInt256(int256, forColumn: key.stringValue)
            return
        }
        if let uint256 = value as? ClickHouseUInt256 {
            try storage.appendUInt256(uint256, forColumn: key.stringValue)
            return
        }
        if let json = value as? ClickHouseJSON {
            try storage.appendJSON(json.bytes, forColumn: key.stringValue)
            return
        }
        if let decimal = value as? ClickHouseDecimal {
            try storage.appendDecimal(decimal, precision: decimal.precision, scale: decimal.scale, forColumn: key.stringValue)
            return
        }
        if let interval = value as? ClickHouseInterval {
            try storage.appendInterval(interval.value, kind: interval.kind, forColumn: key.stringValue)
            return
        }
        if let variant = value as? ClickHouseVariant {
            try storage.appendVariant(members: variant.members, value: variant.value, forColumn: key.stringValue)
            return
        }
        if let dynamic = value as? ClickHouseDynamic {
            try storage.appendDynamic(value: dynamic.value, forColumn: key.stringValue)
            return
        }
        if let aggregateState = value as? ClickHouseAggregateState {
            try storage.appendAggregateState(signature: aggregateState.signature, bytes: aggregateState.bytes, forColumn: key.stringValue)
            return
        }
        throw ClickHouseError.protocolError(
            stage: "encoder.encode",
            message: "column '\(key.stringValue)' has unsupported Swift type \(String(describing: type(of: value))). The raw Codable layer supports primitives, String, Bool, Float, Double, Date, UUID, and their Optional variants."
        )
    }

    mutating func encodeIfPresent<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if try encodeIfFoundationOptional(value, forKey: key) { return }
        if try encodeIfWrapperOptional(value, forKey: key) { return }
        guard let value else {
            throw ClickHouseError.protocolError(
                stage: "encoder.encodeIfPresent",
                message: "column '\(key.stringValue)' has unsupported Optional Swift type \(String(describing: T.self))."
            )
        }
        try encode(value, forKey: key)
    }

    private mutating func encodeIfFoundationOptional<T: Encodable>(_ value: T?, forKey key: Key) throws -> Bool {
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

    private mutating func encodeIfWrapperOptional<T: Encodable>(_ value: T?, forKey key: Key) throws -> Bool {
        if !isSupportedWrapperOptional(T.self) { return false }
        guard let value else {
            try storage.appendAbsentNullable(forColumn: key.stringValue)
            return true
        }
        try encodePresentWrapper(value, forKey: key)
        return true
    }

    private func isSupportedWrapperOptional<T>(_ type: T.Type) -> Bool {
        if isFixedNumericWrapper(type) { return true }
        if isFixedWidthWrapper(type) { return true }
        if isShapedWrapper(type) { return true }
        return false
    }

    private func isFixedNumericWrapper<T>(_ type: T.Type) -> Bool {
        type == ClickHouseInt128.self || type == ClickHouseUInt128.self
            || type == ClickHouseInt256.self || type == ClickHouseUInt256.self
    }

    private func isFixedWidthWrapper<T>(_ type: T.Type) -> Bool {
        type == ClickHouseDate32.self || type == ClickHouseIPv4.self || type == ClickHouseIPv6.self
            || type == ClickHouseDate.self || type == ClickHouseTime.self
    }

    private func isShapedWrapper<T>(_ type: T.Type) -> Bool {
        type == ClickHouseDateTime64.self || type == ClickHouseFixedString.self
            || type == ClickHouseEnum8.self || type == ClickHouseEnum16.self
            || type == ClickHouseDecimal.self || type == ClickHouseTime64.self
            || type == ClickHouseInterval.self
    }

    private mutating func encodePresentWrapper<T: Encodable>(_ value: T, forKey key: Key) throws {
        if try encodePresentFixedNumeric(value, forKey: key) { return }
        if try encodePresentFixedWidth(value, forKey: key) { return }
        try encodePresentShaped(value, forKey: key)
    }

    private mutating func encodePresentFixedNumeric<T: Encodable>(_ value: T, forKey key: Key) throws -> Bool {
        if let int128 = value as? ClickHouseInt128 {
            try storage.appendNullableInt128(.present(int128.value), forColumn: key.stringValue)
            return true
        }
        if let uint128 = value as? ClickHouseUInt128 {
            try storage.appendNullableUInt128(.present(uint128.value), forColumn: key.stringValue)
            return true
        }
        if let int256 = value as? ClickHouseInt256 {
            try storage.appendNullableInt256(.present(int256), forColumn: key.stringValue)
            return true
        }
        if let uint256 = value as? ClickHouseUInt256 {
            try storage.appendNullableUInt256(.present(uint256), forColumn: key.stringValue)
            return true
        }
        return false
    }

    private mutating func encodePresentFixedWidth<T: Encodable>(_ value: T, forKey key: Key) throws -> Bool {
        if let date32 = value as? ClickHouseDate32 {
            try storage.appendNullableDate32(.present(date32.days), forColumn: key.stringValue)
            return true
        }
        if let ipv4 = value as? ClickHouseIPv4 {
            try storage.appendNullableIPv4(.present(ipv4.raw), forColumn: key.stringValue)
            return true
        }
        if let ipv6 = value as? ClickHouseIPv6 {
            try storage.appendNullableIPv6(.present(ipv6.bytes), forColumn: key.stringValue)
            return true
        }
        if let date = value as? ClickHouseDate {
            try storage.appendNullableDate(.present(date.days), forColumn: key.stringValue)
            return true
        }
        if let time = value as? ClickHouseTime {
            try storage.appendNullableTime(.present(time.seconds), forColumn: key.stringValue)
            return true
        }
        return false
    }

    private mutating func encodePresentShaped<T: Encodable>(_ value: T, forKey key: Key) throws {
        if let dateTime64 = value as? ClickHouseDateTime64 {
            try storage.appendNullableDateTime64(.present(dateTime64), precision: dateTime64.precision, forColumn: key.stringValue)
            return
        }
        if let fixedString = value as? ClickHouseFixedString {
            try storage.appendNullableFixedString(.present(fixedString.bytes), length: fixedString.length, forColumn: key.stringValue)
            return
        }
        if let enum8 = value as? ClickHouseEnum8 {
            try storage.appendNullableEnum8(.present(enum8.value), mapping: enum8.mapping, forColumn: key.stringValue)
            return
        }
        if let enum16 = value as? ClickHouseEnum16 {
            try storage.appendNullableEnum16(.present(enum16.value), mapping: enum16.mapping, forColumn: key.stringValue)
            return
        }
        if let decimal = value as? ClickHouseDecimal {
            try storage.appendNullableDecimal(.present(decimal), precision: decimal.precision, scale: decimal.scale, forColumn: key.stringValue)
            return
        }
        if let time64 = value as? ClickHouseTime64 {
            try storage.appendNullableTime64(.present(time64), precision: time64.precision, forColumn: key.stringValue)
            return
        }
        if let interval = value as? ClickHouseInterval {
            try storage.appendNullableInterval(.present(interval.value), kind: interval.kind, forColumn: key.stringValue)
            return
        }
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
