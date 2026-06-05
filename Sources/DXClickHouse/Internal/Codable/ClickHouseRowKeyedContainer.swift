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
        // A native Swift array of a supported scalar element encodes into an
        // Array(T) column, so callers insert [String] / [Int64] / [Double] /
        // [Bool] directly rather than wrapping in ClickHouseArray. The
        // dispatch keys on the STATIC element type, not a `value as? [T]`
        // cast: an empty array casts successfully to every element type
        // (there are no elements to check), so a runtime cast would tag an
        // empty [Int64] as Array(String) and desync the column type.
        if T.self == [String].self, let strings = value as? [String] {
            try storage.appendArray(strings.map { Array($0.utf8) }, element: .string, forColumn: key.stringValue)
            return
        }
        // [ClickHouseDecimal] mirrors the native Array(Decimal) decode. The
        // element's precision and scale come from the values (they are not in
        // the Swift type), so an empty array cannot determine them and is
        // rejected toward the explicit ClickHouseArray.
        if T.self == [ClickHouseDecimal].self, let decimals = value as? [ClickHouseDecimal] {
            try appendDecimalArray(decimals, forColumn: key.stringValue)
            return
        }
        // [ClickHouseFixedString] mirrors the native Array(FixedString(N))
        // decode. The width is carried by each value, so a non-empty array
        // is unambiguous; an empty array cannot determine it.
        if T.self == [ClickHouseFixedString].self, let values = value as? [ClickHouseFixedString] {
            try appendFixedStringArray(values, forColumn: key.stringValue)
            return
        }
        // [ClickHouseDateTime64] mirrors the native Array(DateTime64(P))
        // decode. Each value carries its precision, so a non-empty array is
        // unambiguous; an empty array cannot determine it.
        if T.self == [ClickHouseDateTime64].self, let values = value as? [ClickHouseDateTime64] {
            try appendDateTime64Array(values, forColumn: key.stringValue)
            return
        }
        // [ClickHouseEnum8/16] mirror the native Array(Enum8/16) decode. Each
        // value carries the column's name mapping, so a non-empty array is
        // unambiguous; an empty array cannot determine it.
        if T.self == [ClickHouseEnum8].self, let values = value as? [ClickHouseEnum8] {
            try appendEnum8Array(values, forColumn: key.stringValue)
            return
        }
        if T.self == [ClickHouseEnum16].self, let values = value as? [ClickHouseEnum16] {
            try appendEnum16Array(values, forColumn: key.stringValue)
            return
        }
        // [UUID] mirrors the native Array(UUID) decode. UUID is a fixed
        // 16-byte element, so even an empty array is unambiguous; each value
        // is written in ClickHouse's half-reversed wire order.
        if T.self == [UUID].self, let uuids = value as? [UUID] {
            try storage.appendArray(uuids.map { ClickHouseUUIDWire.wireBytes(from: $0) }, element: .uuid, forColumn: key.stringValue)
            return
        }
        // [ClickHouseIPv4] is a 4-byte little-endian integer; [ClickHouseIPv6]
        // is 16 network-order bytes. Both are fixed-width, so even an empty
        // array is unambiguous.
        if T.self == [ClickHouseIPv4].self, let values = value as? [ClickHouseIPv4] {
            try storage.appendArray(values.map { Self.littleEndianBytes($0.raw) }, element: .ipv4, forColumn: key.stringValue)
            return
        }
        if T.self == [ClickHouseIPv6].self, let values = value as? [ClickHouseIPv6] {
            try storage.appendArray(values.map { $0.bytes }, element: .ipv6, forColumn: key.stringValue)
            return
        }
        // [ClickHouseInt128/UInt128]: 16 little-endian bytes per value, fixed
        // width, so even an empty array is unambiguous.
        if T.self == [ClickHouseInt128].self, let values = value as? [ClickHouseInt128] {
            try storage.appendArray(values.map { Self.littleEndianBytes($0.value) }, element: .int128, forColumn: key.stringValue)
            return
        }
        if T.self == [ClickHouseUInt128].self, let values = value as? [ClickHouseUInt128] {
            try storage.appendArray(values.map { Self.littleEndianBytes($0.value) }, element: .uint128, forColumn: key.stringValue)
            return
        }
        // [ClickHouseInt256/UInt256]: 32 bytes (four little-endian limbs) per
        // value, fixed width, so even an empty array is unambiguous.
        if T.self == [ClickHouseInt256].self, let values = value as? [ClickHouseInt256] {
            try storage.appendArray(values.map { $0.littleEndianBytes }, element: .int256, forColumn: key.stringValue)
            return
        }
        if T.self == [ClickHouseUInt256].self, let values = value as? [ClickHouseUInt256] {
            try storage.appendArray(values.map { $0.littleEndianBytes }, element: .uint256, forColumn: key.stringValue)
            return
        }
        // [Date] mirrors the scalar Date encode: it maps to Array(DateTime)
        // (epoch seconds), so there is no element metadata to infer and even
        // an empty array is unambiguous. Each instant is range-checked.
        if T.self == [Date].self, let dates = value as? [Date] {
            try storage.appendDateTimeArray(dates, forColumn: key.stringValue)
            return
        }
        if T.self == [Bool].self, let bools = value as? [Bool] {
            try storage.appendArray(bools.map { [$0 ? 1 : 0] }, element: .bool, forColumn: key.stringValue)
            return
        }
        if T.self == [Int8].self, let values = value as? [Int8] {
            try storage.appendArray(values.map { [UInt8(bitPattern: $0)] }, element: .int8, forColumn: key.stringValue)
            return
        }
        if T.self == [UInt8].self, let values = value as? [UInt8] {
            try storage.appendArray(values.map { [$0] }, element: .uint8, forColumn: key.stringValue)
            return
        }
        if T.self == [Int16].self, let values = value as? [Int16] {
            try storage.appendArray(values.map { Self.littleEndianBytes(UInt16(bitPattern: $0)) }, element: .int16, forColumn: key.stringValue)
            return
        }
        if T.self == [UInt16].self, let values = value as? [UInt16] {
            try storage.appendArray(values.map { Self.littleEndianBytes($0) }, element: .uint16, forColumn: key.stringValue)
            return
        }
        if T.self == [Int32].self, let values = value as? [Int32] {
            try storage.appendArray(values.map { Self.littleEndianBytes(UInt32(bitPattern: $0)) }, element: .int32, forColumn: key.stringValue)
            return
        }
        if T.self == [UInt32].self, let values = value as? [UInt32] {
            try storage.appendArray(values.map { Self.littleEndianBytes($0) }, element: .uint32, forColumn: key.stringValue)
            return
        }
        if T.self == [Int64].self, let values = value as? [Int64] {
            try storage.appendArray(values.map { Self.littleEndianBytes(UInt64(bitPattern: $0)) }, element: .int64, forColumn: key.stringValue)
            return
        }
        if T.self == [UInt64].self, let values = value as? [UInt64] {
            try storage.appendArray(values.map { Self.littleEndianBytes($0) }, element: .uint64, forColumn: key.stringValue)
            return
        }
        if T.self == [Float].self, let values = value as? [Float] {
            try storage.appendArray(values.map { Self.littleEndianBytes($0.bitPattern) }, element: .float32, forColumn: key.stringValue)
            return
        }
        if T.self == [Double].self, let values = value as? [Double] {
            try storage.appendArray(values.map { Self.littleEndianBytes($0.bitPattern) }, element: .float64, forColumn: key.stringValue)
            return
        }
        // Array(Array(T)): nested arrays.
        if T.self == [[String]].self, let nested = value as? [[String]] {
            try appendNestedArray(nested, element: .string, forColumn: key.stringValue) { Array($0.utf8) }
            return
        }
        if T.self == [[Bool]].self, let nested = value as? [[Bool]] {
            try appendNestedArray(nested, element: .bool, forColumn: key.stringValue) { [$0 ? 1 : 0] }
            return
        }
        if T.self == [[Int8]].self, let nested = value as? [[Int8]] {
            try appendNestedArray(nested, element: .int8, forColumn: key.stringValue) { [UInt8(bitPattern: $0)] }
            return
        }
        if T.self == [[UInt8]].self, let nested = value as? [[UInt8]] {
            try appendNestedArray(nested, element: .uint8, forColumn: key.stringValue) { [$0] }
            return
        }
        if T.self == [[Int16]].self, let nested = value as? [[Int16]] {
            try appendNestedArray(nested, element: .int16, forColumn: key.stringValue) { Self.littleEndianBytes(UInt16(bitPattern: $0)) }
            return
        }
        if T.self == [[UInt16]].self, let nested = value as? [[UInt16]] {
            try appendNestedArray(nested, element: .uint16, forColumn: key.stringValue) { Self.littleEndianBytes($0) }
            return
        }
        if T.self == [[Int32]].self, let nested = value as? [[Int32]] {
            try appendNestedArray(nested, element: .int32, forColumn: key.stringValue) { Self.littleEndianBytes(UInt32(bitPattern: $0)) }
            return
        }
        if T.self == [[UInt32]].self, let nested = value as? [[UInt32]] {
            try appendNestedArray(nested, element: .uint32, forColumn: key.stringValue) { Self.littleEndianBytes($0) }
            return
        }
        if T.self == [[Int64]].self, let nested = value as? [[Int64]] {
            try appendNestedArray(nested, element: .int64, forColumn: key.stringValue) { Self.littleEndianBytes(UInt64(bitPattern: $0)) }
            return
        }
        if T.self == [[UInt64]].self, let nested = value as? [[UInt64]] {
            try appendNestedArray(nested, element: .uint64, forColumn: key.stringValue) { Self.littleEndianBytes($0) }
            return
        }
        if T.self == [[Float]].self, let nested = value as? [[Float]] {
            try appendNestedArray(nested, element: .float32, forColumn: key.stringValue) { Self.littleEndianBytes($0.bitPattern) }
            return
        }
        if T.self == [[Double]].self, let nested = value as? [[Double]] {
            try appendNestedArray(nested, element: .float64, forColumn: key.stringValue) { Self.littleEndianBytes($0.bitPattern) }
            return
        }
        // Array(Nullable(T)): an array column whose elements may individually be
        // NULL, mirroring the decode side. Each Swift optional element becomes a
        // present/absent wrapper over the element's wire bytes.
        if T.self == [String?].self, let values = value as? [String?] {
            try storage.appendArrayOfNullable(Self.toNullableBytes(values) { Array($0.utf8) }, element: .string, forColumn: key.stringValue)
            return
        }
        if T.self == [Bool?].self, let values = value as? [Bool?] {
            try storage.appendArrayOfNullable(Self.toNullableBytes(values) { [$0 ? 1 : 0] }, element: .bool, forColumn: key.stringValue)
            return
        }
        if T.self == [Int8?].self, let values = value as? [Int8?] {
            try storage.appendArrayOfNullable(Self.toNullableBytes(values) { [UInt8(bitPattern: $0)] }, element: .int8, forColumn: key.stringValue)
            return
        }
        if T.self == [UInt8?].self, let values = value as? [UInt8?] {
            try storage.appendArrayOfNullable(Self.toNullableBytes(values) { [$0] }, element: .uint8, forColumn: key.stringValue)
            return
        }
        if T.self == [Int16?].self, let values = value as? [Int16?] {
            try storage.appendArrayOfNullable(Self.toNullableBytes(values) { Self.littleEndianBytes(UInt16(bitPattern: $0)) }, element: .int16, forColumn: key.stringValue)
            return
        }
        if T.self == [UInt16?].self, let values = value as? [UInt16?] {
            try storage.appendArrayOfNullable(Self.toNullableBytes(values) { Self.littleEndianBytes($0) }, element: .uint16, forColumn: key.stringValue)
            return
        }
        if T.self == [Int32?].self, let values = value as? [Int32?] {
            try storage.appendArrayOfNullable(Self.toNullableBytes(values) { Self.littleEndianBytes(UInt32(bitPattern: $0)) }, element: .int32, forColumn: key.stringValue)
            return
        }
        if T.self == [UInt32?].self, let values = value as? [UInt32?] {
            try storage.appendArrayOfNullable(Self.toNullableBytes(values) { Self.littleEndianBytes($0) }, element: .uint32, forColumn: key.stringValue)
            return
        }
        if T.self == [Int64?].self, let values = value as? [Int64?] {
            try storage.appendArrayOfNullable(Self.toNullableBytes(values) { Self.littleEndianBytes(UInt64(bitPattern: $0)) }, element: .int64, forColumn: key.stringValue)
            return
        }
        if T.self == [UInt64?].self, let values = value as? [UInt64?] {
            try storage.appendArrayOfNullable(Self.toNullableBytes(values) { Self.littleEndianBytes($0) }, element: .uint64, forColumn: key.stringValue)
            return
        }
        if T.self == [Float?].self, let values = value as? [Float?] {
            try storage.appendArrayOfNullable(Self.toNullableBytes(values) { Self.littleEndianBytes($0.bitPattern) }, element: .float32, forColumn: key.stringValue)
            return
        }
        if T.self == [Double?].self, let values = value as? [Double?] {
            try storage.appendArrayOfNullable(Self.toNullableBytes(values) { Self.littleEndianBytes($0.bitPattern) }, element: .float64, forColumn: key.stringValue)
            return
        }
        if T.self == [UUID?].self, let values = value as? [UUID?] {
            try storage.appendArrayOfNullable(Self.toNullableBytes(values) { ClickHouseUUIDWire.wireBytes(from: $0) }, element: .uuid, forColumn: key.stringValue)
            return
        }
        if T.self == [ClickHouseIPv4?].self, let values = value as? [ClickHouseIPv4?] {
            try storage.appendArrayOfNullable(Self.toNullableBytes(values) { Self.littleEndianBytes($0.raw) }, element: .ipv4, forColumn: key.stringValue)
            return
        }
        if T.self == [ClickHouseIPv6?].self, let values = value as? [ClickHouseIPv6?] {
            try storage.appendArrayOfNullable(Self.toNullableBytes(values) { $0.bytes }, element: .ipv6, forColumn: key.stringValue)
            return
        }
        if T.self == [ClickHouseInt128?].self, let values = value as? [ClickHouseInt128?] {
            try storage.appendArrayOfNullable(Self.toNullableBytes(values) { Self.littleEndianBytes($0.value) }, element: .int128, forColumn: key.stringValue)
            return
        }
        if T.self == [ClickHouseUInt128?].self, let values = value as? [ClickHouseUInt128?] {
            try storage.appendArrayOfNullable(Self.toNullableBytes(values) { Self.littleEndianBytes($0.value) }, element: .uint128, forColumn: key.stringValue)
            return
        }
        if T.self == [ClickHouseInt256?].self, let values = value as? [ClickHouseInt256?] {
            try storage.appendArrayOfNullable(Self.toNullableBytes(values) { $0.littleEndianBytes }, element: .int256, forColumn: key.stringValue)
            return
        }
        if T.self == [ClickHouseUInt256?].self, let values = value as? [ClickHouseUInt256?] {
            try storage.appendArrayOfNullable(Self.toNullableBytes(values) { $0.littleEndianBytes }, element: .uint256, forColumn: key.stringValue)
            return
        }
        if T.self == [ClickHouseFixedString?].self, let values = value as? [ClickHouseFixedString?] {
            try appendNullableFixedStringArray(values, forColumn: key.stringValue)
            return
        }
        if T.self == [ClickHouseDecimal?].self, let values = value as? [ClickHouseDecimal?] {
            try appendNullableDecimalArray(values, forColumn: key.stringValue)
            return
        }
        if T.self == [ClickHouseDateTime64?].self, let values = value as? [ClickHouseDateTime64?] {
            try appendNullableDateTime64Array(values, forColumn: key.stringValue)
            return
        }
        if T.self == [Date?].self, let dates = value as? [Date?] {
            let wrapped: [ClickHouseNullable<Date>] = dates.map { date in
                guard let date else { return .absent }
                return .present(date)
            }
            try storage.appendNullableDateTimeArray(wrapped, forColumn: key.stringValue)
            return
        }
        if T.self == [ClickHouseEnum8?].self, let values = value as? [ClickHouseEnum8?] {
            try appendNullableEnum8Array(values, forColumn: key.stringValue)
            return
        }
        if T.self == [ClickHouseEnum16?].self, let values = value as? [ClickHouseEnum16?] {
            try appendNullableEnum16Array(values, forColumn: key.stringValue)
            return
        }
        // A native Swift [String: V] with a String key and a supported scalar
        // value encodes into a Map(String, V) column (tags/labels and the
        // observability metric maps). Keyed on the static type so an empty
        // dictionary keeps its declared value element type.
        if T.self == [String: String].self, let dictionary = value as? [String: String] {
            try appendStringKeyedMap(dictionary, valueElement: .string, forColumn: key.stringValue) { Array($0.utf8) }
            return
        }
        if T.self == [String: Int64].self, let dictionary = value as? [String: Int64] {
            try appendStringKeyedMap(dictionary, valueElement: .int64, forColumn: key.stringValue) { Self.littleEndianBytes(UInt64(bitPattern: $0)) }
            return
        }
        if T.self == [String: UInt64].self, let dictionary = value as? [String: UInt64] {
            try appendStringKeyedMap(dictionary, valueElement: .uint64, forColumn: key.stringValue) { Self.littleEndianBytes($0) }
            return
        }
        if T.self == [String: Double].self, let dictionary = value as? [String: Double] {
            try appendStringKeyedMap(dictionary, valueElement: .float64, forColumn: key.stringValue) { Self.littleEndianBytes($0.bitPattern) }
            return
        }
        if T.self == [String: Int8].self, let dictionary = value as? [String: Int8] {
            try appendStringKeyedMap(dictionary, valueElement: .int8, forColumn: key.stringValue) { [UInt8(bitPattern: $0)] }
            return
        }
        if T.self == [String: Int16].self, let dictionary = value as? [String: Int16] {
            try appendStringKeyedMap(dictionary, valueElement: .int16, forColumn: key.stringValue) { Self.littleEndianBytes(UInt16(bitPattern: $0)) }
            return
        }
        if T.self == [String: Int32].self, let dictionary = value as? [String: Int32] {
            try appendStringKeyedMap(dictionary, valueElement: .int32, forColumn: key.stringValue) { Self.littleEndianBytes(UInt32(bitPattern: $0)) }
            return
        }
        if T.self == [String: UInt8].self, let dictionary = value as? [String: UInt8] {
            try appendStringKeyedMap(dictionary, valueElement: .uint8, forColumn: key.stringValue) { [$0] }
            return
        }
        if T.self == [String: UInt16].self, let dictionary = value as? [String: UInt16] {
            try appendStringKeyedMap(dictionary, valueElement: .uint16, forColumn: key.stringValue) { Self.littleEndianBytes($0) }
            return
        }
        if T.self == [String: UInt32].self, let dictionary = value as? [String: UInt32] {
            try appendStringKeyedMap(dictionary, valueElement: .uint32, forColumn: key.stringValue) { Self.littleEndianBytes($0) }
            return
        }
        if T.self == [String: Float].self, let dictionary = value as? [String: Float] {
            try appendStringKeyedMap(dictionary, valueElement: .float32, forColumn: key.stringValue) { Self.littleEndianBytes($0.bitPattern) }
            return
        }
        if T.self == [String: Bool].self, let dictionary = value as? [String: Bool] {
            try appendStringKeyedMap(dictionary, valueElement: .bool, forColumn: key.stringValue) { [$0 ? 1 : 0] }
            return
        }
        // Map(String, Array(V)): a String-keyed map whose values are arrays
        // (multi-value attributes / per-key metric series).
        if T.self == [String: [String]].self, let dictionary = value as? [String: [String]] {
            try appendStringKeyedArrayMap(dictionary, valueElement: .string, forColumn: key.stringValue) { Array($0.utf8) }
            return
        }
        if T.self == [String: [Int64]].self, let dictionary = value as? [String: [Int64]] {
            try appendStringKeyedArrayMap(dictionary, valueElement: .int64, forColumn: key.stringValue) { Self.littleEndianBytes(UInt64(bitPattern: $0)) }
            return
        }
        if T.self == [String: [UInt64]].self, let dictionary = value as? [String: [UInt64]] {
            try appendStringKeyedArrayMap(dictionary, valueElement: .uint64, forColumn: key.stringValue) { Self.littleEndianBytes($0) }
            return
        }
        if T.self == [String: [Double]].self, let dictionary = value as? [String: [Double]] {
            try appendStringKeyedArrayMap(dictionary, valueElement: .float64, forColumn: key.stringValue) { Self.littleEndianBytes($0.bitPattern) }
            return
        }
        if T.self == [String: [Int32]].self, let dictionary = value as? [String: [Int32]] {
            try appendStringKeyedArrayMap(dictionary, valueElement: .int32, forColumn: key.stringValue) { Self.littleEndianBytes(UInt32(bitPattern: $0)) }
            return
        }
        if T.self == [String: [Float]].self, let dictionary = value as? [String: [Float]] {
            try appendStringKeyedArrayMap(dictionary, valueElement: .float32, forColumn: key.stringValue) { Self.littleEndianBytes($0.bitPattern) }
            return
        }
        if T.self == [String: [Bool]].self, let dictionary = value as? [String: [Bool]] {
            try appendStringKeyedArrayMap(dictionary, valueElement: .bool, forColumn: key.stringValue) { [$0 ? 1 : 0] }
            return
        }
        // Map with integer keys (Map(Int64, V) / Map(UInt64, V)).
        if T.self == [Int64: String].self, let dictionary = value as? [Int64: String] {
            try appendKeyedMap(dictionary, keyElement: .int64, valueElement: .string, forColumn: key.stringValue, keyConvert: { Self.littleEndianBytes(UInt64(bitPattern: $0)) }, valueConvert: { Array($0.utf8) })
            return
        }
        if T.self == [UInt64: String].self, let dictionary = value as? [UInt64: String] {
            try appendKeyedMap(dictionary, keyElement: .uint64, valueElement: .string, forColumn: key.stringValue, keyConvert: { Self.littleEndianBytes($0) }, valueConvert: { Array($0.utf8) })
            return
        }
        if T.self == [Int64: Int64].self, let dictionary = value as? [Int64: Int64] {
            try appendKeyedMap(dictionary, keyElement: .int64, valueElement: .int64, forColumn: key.stringValue, keyConvert: { Self.littleEndianBytes(UInt64(bitPattern: $0)) }, valueConvert: { Self.littleEndianBytes(UInt64(bitPattern: $0)) })
            return
        }
        if T.self == [UInt64: Int64].self, let dictionary = value as? [UInt64: Int64] {
            try appendKeyedMap(dictionary, keyElement: .uint64, valueElement: .int64, forColumn: key.stringValue, keyConvert: { Self.littleEndianBytes($0) }, valueConvert: { Self.littleEndianBytes(UInt64(bitPattern: $0)) })
            return
        }
        // Map(String, Nullable(V)): a String-keyed map whose values may be NULL.
        if T.self == [String: String?].self, let dictionary = value as? [String: String?] {
            try appendNullableStringKeyedMap(dictionary, valueElement: .string, forColumn: key.stringValue) { Array($0.utf8) }
            return
        }
        if T.self == [String: Int64?].self, let dictionary = value as? [String: Int64?] {
            try appendNullableStringKeyedMap(dictionary, valueElement: .int64, forColumn: key.stringValue) { Self.littleEndianBytes(UInt64(bitPattern: $0)) }
            return
        }
        if T.self == [String: UInt64?].self, let dictionary = value as? [String: UInt64?] {
            try appendNullableStringKeyedMap(dictionary, valueElement: .uint64, forColumn: key.stringValue) { Self.littleEndianBytes($0) }
            return
        }
        if T.self == [String: Double?].self, let dictionary = value as? [String: Double?] {
            try appendNullableStringKeyedMap(dictionary, valueElement: .float64, forColumn: key.stringValue) { Self.littleEndianBytes($0.bitPattern) }
            return
        }
        if T.self == [String: Int8?].self, let dictionary = value as? [String: Int8?] {
            try appendNullableStringKeyedMap(dictionary, valueElement: .int8, forColumn: key.stringValue) { [UInt8(bitPattern: $0)] }
            return
        }
        if T.self == [String: Int16?].self, let dictionary = value as? [String: Int16?] {
            try appendNullableStringKeyedMap(dictionary, valueElement: .int16, forColumn: key.stringValue) { Self.littleEndianBytes(UInt16(bitPattern: $0)) }
            return
        }
        if T.self == [String: Int32?].self, let dictionary = value as? [String: Int32?] {
            try appendNullableStringKeyedMap(dictionary, valueElement: .int32, forColumn: key.stringValue) { Self.littleEndianBytes(UInt32(bitPattern: $0)) }
            return
        }
        if T.self == [String: UInt8?].self, let dictionary = value as? [String: UInt8?] {
            try appendNullableStringKeyedMap(dictionary, valueElement: .uint8, forColumn: key.stringValue) { [$0] }
            return
        }
        if T.self == [String: UInt16?].self, let dictionary = value as? [String: UInt16?] {
            try appendNullableStringKeyedMap(dictionary, valueElement: .uint16, forColumn: key.stringValue) { Self.littleEndianBytes($0) }
            return
        }
        if T.self == [String: UInt32?].self, let dictionary = value as? [String: UInt32?] {
            try appendNullableStringKeyedMap(dictionary, valueElement: .uint32, forColumn: key.stringValue) { Self.littleEndianBytes($0) }
            return
        }
        if T.self == [String: Float?].self, let dictionary = value as? [String: Float?] {
            try appendNullableStringKeyedMap(dictionary, valueElement: .float32, forColumn: key.stringValue) { Self.littleEndianBytes($0.bitPattern) }
            return
        }
        if T.self == [String: Bool?].self, let dictionary = value as? [String: Bool?] {
            try appendNullableStringKeyedMap(dictionary, valueElement: .bool, forColumn: key.stringValue) { [$0 ? 1 : 0] }
            return
        }
        if T.self == [Int64: String?].self, let dictionary = value as? [Int64: String?] {
            try appendNullableKeyedMap(dictionary, keyElement: .int64, valueElement: .string, forColumn: key.stringValue, keyConvert: { Self.littleEndianBytes(UInt64(bitPattern: $0)) }, valueConvert: { Array($0.utf8) })
            return
        }
        if T.self == [UInt64: String?].self, let dictionary = value as? [UInt64: String?] {
            try appendNullableKeyedMap(dictionary, keyElement: .uint64, valueElement: .string, forColumn: key.stringValue, keyConvert: { Self.littleEndianBytes($0) }, valueConvert: { Array($0.utf8) })
            return
        }
        if T.self == [Int64: Int64?].self, let dictionary = value as? [Int64: Int64?] {
            try appendNullableKeyedMap(dictionary, keyElement: .int64, valueElement: .int64, forColumn: key.stringValue, keyConvert: { Self.littleEndianBytes(UInt64(bitPattern: $0)) }, valueConvert: { Self.littleEndianBytes(UInt64(bitPattern: $0)) })
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
        // Foundation.Decimal reads back from a ClickHouse Decimal column but
        // cannot be inserted directly: a Decimal(P, S) column needs an
        // explicit precision and scale that a Foundation.Decimal does not
        // carry, and its Codable form would otherwise hit the opaque keyed-
        // container reject below. Point the caller at the typed wrapper.
        // Foundation.Decimal reads back from a ClickHouse Decimal column but
        // cannot be inserted directly: a Decimal(P, S) column needs an
        // explicit precision and scale that a Foundation.Decimal does not
        // carry, and its Codable form would otherwise hit the opaque keyed-
        // container reject below. Point the caller at the typed wrapper.
        if value is Decimal {
            throw ClickHouseError.protocolError(
                stage: "encoder.decimal",
                message: "Foundation.Decimal cannot be inserted directly; a ClickHouse Decimal column requires an explicit precision and scale. Wrap the value as ClickHouseDecimal(unscaled:precision:scale:) for column '\(key.stringValue)'."
            )
        }
        // A collection value reaching here matched none of the supported
        // native [T] / [K: V] shapes. The generic encode(to:) below asks for
        // an unkeyed/keyed container, which a non-empty collection rejects
        // element-by-element but an EMPTY one would silently drop — leaving
        // the row one column short and corrupting the INSERT. Reject any
        // unsupported collection up front so the column count stays correct.
        if value is any Sequence {
            throw ClickHouseError.protocolError(
                stage: "encoder.unsupportedCollection",
                message: "column '\(key.stringValue)' holds a collection of an unsupported element type; use a supported native array ([Int32], [String], [Date], [ClickHouseDecimal], [ClickHouseFixedString], …), an array of tuples as ClickHouseArrayOfTuple, or the ClickHouseArray escape hatch"
            )
        }
        // Delegate any remaining value to its own encode(to:) over a
        // single-value view of the column. This makes a RawRepresentable
        // enum field (a status / category column modelled as a Swift enum)
        // round-trip: the enum's synthesized encoder writes its RawValue
        // (Int32, String, …) through the single-value container, which
        // forwards to this container's typed encode for the same key.
        let columnEncoder = ClickHouseColumnValueEncoder(container: self, key: key, nullable: false, codingPath: codingPath + [key])
        try value.encode(to: columnEncoder)
    }

    mutating func encodeIfPresent<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if try encodeIfFoundationOptional(value, forKey: key) { return }
        if try encodeIfJSONOptional(value, forKey: key) { return }
        if try encodeIfWrapperOptional(value, forKey: key) { return }
        guard let value else {
            // A nil value of an Optional whose Wrapped is not a Foundation
            // type or a ClickHouse wrapper (chiefly a RawRepresentable enum):
            // the column must already have been declared Nullable by a prior
            // present row, which encodes through the nullable single-value
            // path below.
            try storage.appendAbsentNullable(forColumn: key.stringValue)
            return
        }
        // A present Optional<Foundation.Decimal>: same limitation as the
        // non-optional case — a Decimal(P, S) column needs an explicit
        // precision and scale. Surface the actionable error here too rather
        // than the opaque nested-container reject the Codable form would hit.
        if value is Decimal {
            throw ClickHouseError.protocolError(
                stage: "encoder.decimal",
                message: "Foundation.Decimal cannot be inserted directly; a ClickHouse Decimal column requires an explicit precision and scale. Wrap the value as ClickHouseDecimal(unscaled:precision:scale:) for column '\(key.stringValue)'."
            )
        }
        // A present optional collection ([T]?, [K: V]?): ClickHouse Array and
        // Map columns are not nullable — they default to an empty collection,
        // never NULL — so there is no Nullable column to encode into. State
        // that plainly instead of the misleading nested-container reject.
        if value is any Sequence {
            throw ClickHouseError.protocolError(
                stage: "encoder.nullableCollection",
                message: "ClickHouse Array and Map columns are not nullable, so an optional collection cannot be encoded for column '\(key.stringValue)'. Use a non-optional [T] / [K: V] field (an empty collection means no values)."
            )
        }
        // A present value of such an Optional: encode it through a nullable
        // single-value view so the column is registered Nullable(underlying),
        // matching the Optional field, and absent rows append a NULL cleanly.
        let columnEncoder = ClickHouseColumnValueEncoder(container: self, key: key, nullable: true, codingPath: codingPath + [key])
        try value.encode(to: columnEncoder)
    }

    // ClickHouseJSON is String-compatible, so an optional JSON field is a
    // Nullable(String) column whose type is fully determined by T — a nil
    // first row establishes it cleanly, unlike a shaped wrapper. Route both
    // present and absent through the nullable-string accumulator.
    private mutating func encodeIfJSONOptional<T: Encodable>(_ value: T?, forKey key: Key) throws -> Bool {
        guard T.self == ClickHouseJSON.self else { return false }
        let nullable: ClickHouseNullable<String> = (value as? ClickHouseJSON).map { .present($0.text) } ?? .absent
        try storage.appendNullableString(nullable, forColumn: key.stringValue)
        return true
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
            try encodeAbsentWrapper(T.self, forKey: key)
            return true
        }
        try encodePresentWrapper(value, forKey: key)
        return true
    }

    // A nil wrapper-optional on a row. For fixed-numeric and fixed-width
    // wrapper types the ClickHouse type is fully determined by `T` alone,
    // so the column can be registered as Nullable even when the very first
    // encoded row is nil. Shaped wrappers (Decimal, FixedString, Enum,
    // DateTime64, Time64, Interval) carry their precision / length / mapping
    // in the value, so a first-row nil cannot establish the column type;
    // those fall back to appendAbsentNullable, which requires a prior
    // non-null row to have defined the column.
    private mutating func encodeAbsentWrapper<T>(_ type: T.Type, forKey key: Key) throws {
        if try encodeAbsentFixedNumeric(type, forKey: key) { return }
        if try encodeAbsentFixedWidth(type, forKey: key) { return }
        try storage.appendAbsentNullable(forColumn: key.stringValue)
    }

    private mutating func encodeAbsentFixedNumeric<T>(_ type: T.Type, forKey key: Key) throws -> Bool {
        if type == ClickHouseInt128.self {
            try storage.appendNullableInt128(.absent, forColumn: key.stringValue)
            return true
        }
        if type == ClickHouseUInt128.self {
            try storage.appendNullableUInt128(.absent, forColumn: key.stringValue)
            return true
        }
        if type == ClickHouseInt256.self {
            try storage.appendNullableInt256(.absent, forColumn: key.stringValue)
            return true
        }
        if type == ClickHouseUInt256.self {
            try storage.appendNullableUInt256(.absent, forColumn: key.stringValue)
            return true
        }
        return false
    }

    private mutating func encodeAbsentFixedWidth<T>(_ type: T.Type, forKey key: Key) throws -> Bool {
        if type == ClickHouseDate32.self {
            try storage.appendNullableDate32(.absent, forColumn: key.stringValue)
            return true
        }
        if type == ClickHouseIPv4.self {
            try storage.appendNullableIPv4(.absent, forColumn: key.stringValue)
            return true
        }
        if type == ClickHouseIPv6.self {
            try storage.appendNullableIPv6(.absent, forColumn: key.stringValue)
            return true
        }
        if type == ClickHouseDate.self {
            try storage.appendNullableDate(.absent, forColumn: key.stringValue)
            return true
        }
        if type == ClickHouseTime.self {
            try storage.appendNullableTime(.absent, forColumn: key.stringValue)
            return true
        }
        if type == ClickHouseBFloat16.self {
            try storage.appendNullableBFloat16(.absent, forColumn: key.stringValue)
            return true
        }
        return false
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
            || type == ClickHouseBFloat16.self
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
        if let bfloat16 = value as? ClickHouseBFloat16 {
            try storage.appendNullableBFloat16(.present(bfloat16.rawBits), forColumn: key.stringValue)
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

    private static func littleEndianBytes<Value: FixedWidthInteger>(_ value: Value) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    private mutating func appendNestedArray<E>(
        _ value: [[E]],
        element: ClickHouseArrayElementType,
        forColumn name: String,
        _ convert: (E) -> [UInt8]
    ) throws {
        let rows: [[[UInt8]]] = value.map { innerArray in innerArray.map(convert) }
        try storage.appendNestedArray(rows, element: element, forColumn: name)
    }

    private static func toNullableBytes<Element>(_ values: [Element?], _ convert: (Element) -> [UInt8]) -> [ClickHouseNullable<[UInt8]>] {
        values.map { element in
            guard let element else { return .absent }
            return .present(convert(element))
        }
    }

    private mutating func appendStringKeyedMap<V>(
        _ dictionary: [String: V],
        valueElement: ClickHouseArrayElementType,
        forColumn name: String,
        _ convert: (V) -> [UInt8]
    ) throws {
        try appendKeyedMap(dictionary, keyElement: .string, valueElement: valueElement, forColumn: name, keyConvert: { Array($0.utf8) }, valueConvert: convert)
    }

    private mutating func appendStringKeyedArrayMap<V>(
        _ dictionary: [String: [V]],
        valueElement: ClickHouseArrayElementType,
        forColumn name: String,
        _ convert: (V) -> [UInt8]
    ) throws {
        var keyBytes: [[UInt8]] = []
        var valueArrays: [[[UInt8]]] = []
        keyBytes.reserveCapacity(dictionary.count)
        valueArrays.reserveCapacity(dictionary.count)
        for (mapKey, mapValue) in dictionary {
            keyBytes.append(Array(mapKey.utf8))
            valueArrays.append(mapValue.map(convert))
        }
        try storage.appendMapWithArrayValues(keys: keyBytes, values: valueArrays, keyElement: .string, valueElement: valueElement, forColumn: name)
    }

    private mutating func appendKeyedMap<K, V>(
        _ dictionary: [K: V],
        keyElement: ClickHouseArrayElementType,
        valueElement: ClickHouseArrayElementType,
        forColumn name: String,
        keyConvert: (K) -> [UInt8],
        valueConvert: (V) -> [UInt8]
    ) throws {
        var keyBytes: [[UInt8]] = []
        var valueBytes: [[UInt8]] = []
        for (mapKey, mapValue) in dictionary {
            keyBytes.append(keyConvert(mapKey))
            valueBytes.append(valueConvert(mapValue))
        }
        try storage.appendMap(keys: keyBytes, values: valueBytes, keyElement: keyElement, valueElement: valueElement, forColumn: name)
    }

    private mutating func appendNullableStringKeyedMap<V>(
        _ dictionary: [String: V?],
        valueElement: ClickHouseArrayElementType,
        forColumn name: String,
        _ convert: (V) -> [UInt8]
    ) throws {
        try appendNullableKeyedMap(dictionary, keyElement: .string, valueElement: valueElement, forColumn: name, keyConvert: { Array($0.utf8) }, valueConvert: convert)
    }

    private mutating func appendNullableKeyedMap<K, V>(
        _ dictionary: [K: V?],
        keyElement: ClickHouseArrayElementType,
        valueElement: ClickHouseArrayElementType,
        forColumn name: String,
        keyConvert: (K) -> [UInt8],
        valueConvert: (V) -> [UInt8]
    ) throws {
        var keyBytes: [[UInt8]] = []
        var valueBytes: [ClickHouseNullable<[UInt8]>] = []
        for (mapKey, mapValue) in dictionary {
            keyBytes.append(keyConvert(mapKey))
            if let mapValue {
                valueBytes.append(.present(valueConvert(mapValue)))
            } else {
                valueBytes.append(.absent)
            }
        }
        try storage.appendMapWithNullableValues(keys: keyBytes, values: valueBytes, keyElement: keyElement, valueElement: valueElement, forColumn: name)
    }

    private mutating func appendDecimalArray(_ decimals: [ClickHouseDecimal], forColumn name: String) throws(ClickHouseError) {
        guard let first = decimals.first else {
            throw .protocolError(stage: "encoder.decimalArray", message: "cannot infer the Decimal precision and scale of an empty [ClickHouseDecimal] for column '\(name)'; insert via ClickHouseArray(element: .decimal(precision:scale:), elements:) to state them explicitly")
        }
        for decimal in decimals where decimal.precision != first.precision || decimal.scale != first.scale {
            throw .protocolError(stage: "encoder.decimalArray", message: "every element of a Decimal array must share one precision and scale; column '\(name)' mixes them")
        }
        try storage.appendArray(decimals.map { $0.littleEndianBytes }, element: .decimal(precision: first.precision, scale: first.scale), forColumn: name)
    }

    private mutating func appendFixedStringArray(_ values: [ClickHouseFixedString], forColumn name: String) throws(ClickHouseError) {
        guard let first = values.first else {
            throw .protocolError(stage: "encoder.fixedStringArray", message: "cannot infer the FixedString length of an empty [ClickHouseFixedString] for column '\(name)'; insert via ClickHouseArray(element: .fixedString(length:), elements:) to state it explicitly")
        }
        for value in values where value.length != first.length {
            throw .protocolError(stage: "encoder.fixedStringArray", message: "every element of a FixedString array must share one length; column '\(name)' mixes them")
        }
        try storage.appendArray(values.map { $0.bytes }, element: .fixedString(length: first.length), forColumn: name)
    }

    // Like appendFixedStringArray, but elements may be NULL. The column width
    // is inferred from the present elements of the row (the same first-row
    // requirement as the non-nullable form: a row with no present element
    // cannot establish the FixedString width).
    private mutating func appendNullableFixedStringArray(_ values: [ClickHouseFixedString?], forColumn name: String) throws(ClickHouseError) {
        let present = values.compactMap { $0 }
        guard let first = present.first else {
            throw .protocolError(stage: "encoder.fixedStringArray", message: "cannot infer the FixedString length for column '\(name)': this [ClickHouseFixedString?] row has no non-nil element to establish the width; ensure at least one row carries a value.")
        }
        for value in present where value.length != first.length {
            throw .protocolError(stage: "encoder.fixedStringArray", message: "every element of a FixedString array must share one length; column '\(name)' mixes them")
        }
        let wrapped: [ClickHouseNullable<[UInt8]>] = values.map { element in
            guard let element else { return .absent }
            return .present(element.bytes)
        }
        try storage.appendArrayOfNullable(wrapped, element: .fixedString(length: first.length), forColumn: name)
    }

    private mutating func appendNullableDecimalArray(_ values: [ClickHouseDecimal?], forColumn name: String) throws(ClickHouseError) {
        let present = values.compactMap { $0 }
        guard let first = present.first else {
            throw .protocolError(stage: "encoder.decimalArray", message: "cannot infer the Decimal precision/scale for column '\(name)': this [ClickHouseDecimal?] row has no non-nil element; ensure at least one row carries a value.")
        }
        for decimal in present where decimal.precision != first.precision || decimal.scale != first.scale {
            throw .protocolError(stage: "encoder.decimalArray", message: "every element of a Decimal array must share one precision and scale; column '\(name)' mixes them")
        }
        let wrapped: [ClickHouseNullable<[UInt8]>] = values.map { element in
            guard let element else { return .absent }
            return .present(element.littleEndianBytes)
        }
        try storage.appendArrayOfNullable(wrapped, element: .decimal(precision: first.precision, scale: first.scale), forColumn: name)
    }

    private mutating func appendNullableDateTime64Array(_ values: [ClickHouseDateTime64?], forColumn name: String) throws(ClickHouseError) {
        let present = values.compactMap { $0 }
        guard let first = present.first else {
            throw .protocolError(stage: "encoder.dateTime64Array", message: "cannot infer the DateTime64 precision for column '\(name)': this [ClickHouseDateTime64?] row has no non-nil element; ensure at least one row carries a value.")
        }
        for value in present where value.precision != first.precision {
            throw .protocolError(stage: "encoder.dateTime64Array", message: "every element of a DateTime64 array must share one precision; column '\(name)' mixes them")
        }
        let wrapped: [ClickHouseNullable<[UInt8]>] = values.map { element in
            guard let element else { return .absent }
            return .present(Self.littleEndianBytes(UInt64(bitPattern: element.ticks)))
        }
        try storage.appendArrayOfNullable(wrapped, element: .dateTime64(precision: first.precision), forColumn: name)
    }

    private mutating func appendDateTime64Array(_ values: [ClickHouseDateTime64], forColumn name: String) throws(ClickHouseError) {
        guard let first = values.first else {
            throw .protocolError(stage: "encoder.dateTime64Array", message: "cannot infer the DateTime64 precision of an empty [ClickHouseDateTime64] for column '\(name)'; insert via ClickHouseArray(element: .dateTime64(precision:), elements:) to state it explicitly")
        }
        for value in values where value.precision != first.precision {
            throw .protocolError(stage: "encoder.dateTime64Array", message: "every element of a DateTime64 array must share one precision; column '\(name)' mixes them")
        }
        try storage.appendArray(values.map { Self.littleEndianBytes(UInt64(bitPattern: $0.ticks)) }, element: .dateTime64(precision: first.precision), forColumn: name)
    }

    private mutating func appendEnum8Array(_ values: [ClickHouseEnum8], forColumn name: String) throws(ClickHouseError) {
        guard let first = values.first else {
            throw .protocolError(stage: "encoder.enumArray", message: "cannot infer the Enum8 mapping of an empty [ClickHouseEnum8] for column '\(name)'; insert via ClickHouseArray(element: .enum8(mapping:), elements:) to state it explicitly")
        }
        for value in values where value.mapping != first.mapping {
            throw .protocolError(stage: "encoder.enumArray", message: "every element of an Enum8 array must share one mapping; column '\(name)' mixes them")
        }
        try storage.appendEnum8Array(values.map { $0.value }, mapping: first.mapping, forColumn: name)
    }

    private mutating func appendEnum16Array(_ values: [ClickHouseEnum16], forColumn name: String) throws(ClickHouseError) {
        guard let first = values.first else {
            throw .protocolError(stage: "encoder.enumArray", message: "cannot infer the Enum16 mapping of an empty [ClickHouseEnum16] for column '\(name)'; insert via ClickHouseArray(element: .enum16(mapping:), elements:) to state it explicitly")
        }
        for value in values where value.mapping != first.mapping {
            throw .protocolError(stage: "encoder.enumArray", message: "every element of an Enum16 array must share one mapping; column '\(name)' mixes them")
        }
        try storage.appendEnum16Array(values.map { $0.value }, mapping: first.mapping, forColumn: name)
    }

    private mutating func appendNullableEnum8Array(_ values: [ClickHouseEnum8?], forColumn name: String) throws(ClickHouseError) {
        let present = values.compactMap { $0 }
        guard let first = present.first else {
            throw .protocolError(stage: "encoder.enumArray", message: "cannot infer the Enum8 mapping for column '\(name)': this [ClickHouseEnum8?] row has no non-nil element; ensure at least one row carries a value.")
        }
        for value in present where value.mapping != first.mapping {
            throw .protocolError(stage: "encoder.enumArray", message: "every element of an Enum8 array must share one mapping; column '\(name)' mixes them")
        }
        let wrapped: [ClickHouseNullable<Int8>] = values.map { element in
            guard let element else { return .absent }
            return .present(element.value)
        }
        try storage.appendNullableEnum8Array(wrapped, mapping: first.mapping, forColumn: name)
    }

    private mutating func appendNullableEnum16Array(_ values: [ClickHouseEnum16?], forColumn name: String) throws(ClickHouseError) {
        let present = values.compactMap { $0 }
        guard let first = present.first else {
            throw .protocolError(stage: "encoder.enumArray", message: "cannot infer the Enum16 mapping for column '\(name)': this [ClickHouseEnum16?] row has no non-nil element; ensure at least one row carries a value.")
        }
        for value in present where value.mapping != first.mapping {
            throw .protocolError(stage: "encoder.enumArray", message: "every element of an Enum16 array must share one mapping; column '\(name)' mixes them")
        }
        let wrapped: [ClickHouseNullable<Int16>] = values.map { element in
            guard let element else { return .absent }
            return .present(element.value)
        }
        try storage.appendNullableEnum16Array(wrapped, mapping: first.mapping, forColumn: name)
    }

}
