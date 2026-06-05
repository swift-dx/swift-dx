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

// KeyedDecodingContainer that vends fields out of the per-column
// in-memory storage by mapping each CodingKey to a column slot and
// indexing into the typed array at the state's current `rowIndex`.
struct ClickHouseColumnarKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {

    let state: ClickHouseColumnarDecoderState
    var codingPath: [CodingKey]
    var allKeys: [Key] {
        state.columns.compactMap { Key(stringValue: $0.name) }
    }

    func contains(_ key: Key) -> Bool {
        if case .found = state.slot(for: key.stringValue) { return true }
        return false
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        guard case .found(let slot) = state.slot(for: key.stringValue) else {
            throw missing(key)
        }
        return isNullAt(slot: slot)
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        switch try column(forKey: key) {
        case .bool(let values): return values[state.rowIndex]
        case .nullableBool(let values): return try requirePresent(values[state.rowIndex], key: key)
        default: throw typeMismatch(key, expected: "Bool")
        }
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        // nonNullColumn (not column): a Nullable(Enum) / Nullable(
        // LowCardinality(String)) column is carried as the generic
        // .nullable(mask, inner:) wrapper, so it must be unwrapped to its
        // inner column for a present row (and throw valueNotFound on a NULL
        // row) before the inner case can match. The dedicated .nullableString
        // case is unaffected: it is not the generic .nullable wrapper.
        switch try nonNullColumn(forKey: key, expected: "String") {
        case .string(let values): return ClickHouseUTF8.decode(values[state.rowIndex])
        case .stringValues(let values): return values[state.rowIndex]
        case .nullableString(let values): return String(decoding: try requirePresent(values[state.rowIndex], key: key), as: UTF8.self)
        case .fixedString(let values, let length): return ClickHouseFixedString(bytes: values[state.rowIndex], length: length).text
        case .enum8(let values, let mapping): return try enumName(Int16(values[state.rowIndex]), mapping: mapping, key: key)
        case .enum16(let values, let mapping): return try enumName(values[state.rowIndex], mapping: mapping, key: key)
        case .lowCardinality(let values, .string): return ClickHouseUTF8.decode(values[state.rowIndex])
        case .lowCardinality(let values, .fixedString(let length)): return ClickHouseFixedString(bytes: values[state.rowIndex], length: length).text
        default: throw typeMismatch(key, expected: "String")
        }
    }

    private func enumName(_ value: Int16, mapping: [ClickHouseEnumPair], key: Key) throws -> String {
        for pair in mapping where pair.value == value {
            return pair.name
        }
        throw DecodingError.dataCorrupted(.init(
            codingPath: codingPath + [key],
            debugDescription: "Enum value \(value) for column '\(key.stringValue)' is not present in the column's name mapping."
        ))
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        switch try column(forKey: key) {
        case .float64(let values): return values[state.rowIndex]
        case .float32(let values): return Double(values[state.rowIndex])
        case .nullableFloat64(let values): return try requirePresent(values[state.rowIndex], key: key)
        case .nullableFloat32(let values): return Double(try requirePresent(values[state.rowIndex], key: key))
        default: throw typeMismatch(key, expected: "Double")
        }
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        switch try column(forKey: key) {
        case .float32(let values): return values[state.rowIndex]
        case .nullableFloat32(let values): return try requirePresent(values[state.rowIndex], key: key)
        default: throw typeMismatch(key, expected: "Float")
        }
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        throw DecodingError.typeMismatch(Int.self, .init(
            codingPath: codingPath + [key],
            debugDescription: "Swift `Int` is platform-dependent. Decode column '\(key.stringValue)' as a fixed-width integer (Int32, Int64)."
        ))
    }

    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        switch try column(forKey: key) {
        case .int8(let values): return values[state.rowIndex]
        case .nullableInt8(let values): return try requirePresent(values[state.rowIndex], key: key)
        default: throw typeMismatch(key, expected: "Int8")
        }
    }

    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        switch try column(forKey: key) {
        case .int16(let values): return values[state.rowIndex]
        case .nullableInt16(let values): return try requirePresent(values[state.rowIndex], key: key)
        default: throw typeMismatch(key, expected: "Int16")
        }
    }

    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        switch try column(forKey: key) {
        case .int32(let values): return values[state.rowIndex]
        case .nullableInt32(let values): return try requirePresent(values[state.rowIndex], key: key)
        default: throw typeMismatch(key, expected: "Int32")
        }
    }

    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        switch try column(forKey: key) {
        case .int64(let values): return values[state.rowIndex]
        case .nullableInt64(let values): return try requirePresent(values[state.rowIndex], key: key)
        default: throw typeMismatch(key, expected: "Int64")
        }
    }

    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        throw DecodingError.typeMismatch(UInt.self, .init(
            codingPath: codingPath + [key],
            debugDescription: "Swift `UInt` is platform-dependent. Decode column '\(key.stringValue)' as a fixed-width unsigned integer (UInt32, UInt64)."
        ))
    }

    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        switch try column(forKey: key) {
        case .uint8(let values): return values[state.rowIndex]
        case .nullableUInt8(let values): return try requirePresent(values[state.rowIndex], key: key)
        default: throw typeMismatch(key, expected: "UInt8")
        }
    }

    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        switch try column(forKey: key) {
        case .uint16(let values): return values[state.rowIndex]
        case .nullableUInt16(let values): return try requirePresent(values[state.rowIndex], key: key)
        default: throw typeMismatch(key, expected: "UInt16")
        }
    }

    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        switch try column(forKey: key) {
        case .uint32(let values): return values[state.rowIndex]
        case .nullableUInt32(let values): return try requirePresent(values[state.rowIndex], key: key)
        default: throw typeMismatch(key, expected: "UInt32")
        }
    }

    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        switch try column(forKey: key) {
        case .uint64(let values): return values[state.rowIndex]
        case .nullableUInt64(let values): return try requirePresent(values[state.rowIndex], key: key)
        default: throw typeMismatch(key, expected: "UInt64")
        }
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        if T.self == Date.self {
            return try decodeDate(forKey: key) as! T
        }
        if T.self == UUID.self {
            return try decodeUUID(forKey: key) as! T
        }
        if T.self == ClickHouseDateTime64.self {
            return try decodeDateTime64(forKey: key) as! T
        }
        if T.self == ClickHouseFixedString.self {
            return try decodeFixedString(forKey: key) as! T
        }
        if T.self == ClickHouseEnum8.self {
            return try decodeEnum8(forKey: key) as! T
        }
        if T.self == ClickHouseEnum16.self {
            return try decodeEnum16(forKey: key) as! T
        }
        if T.self == ClickHouseLowCardinality.self {
            return try decodeLowCardinality(forKey: key) as! T
        }
        if T.self == ClickHouseArray.self {
            return try decodeArray(forKey: key) as! T
        }
        if T.self == ClickHouseDate32.self {
            return try decodeDate32(forKey: key) as! T
        }
        if T.self == ClickHouseBFloat16.self {
            return try decodeBFloat16(forKey: key) as! T
        }
        if T.self == ClickHouseDate.self {
            return try decodeClickHouseDate(forKey: key) as! T
        }
        if T.self == ClickHouseTime.self {
            return try decodeTime(forKey: key) as! T
        }
        if T.self == ClickHouseTime64.self {
            return try decodeTime64(forKey: key) as! T
        }
        if T.self == ClickHouseIPv4.self {
            return try decodeIPv4(forKey: key) as! T
        }
        if T.self == ClickHouseIPv6.self {
            return try decodeIPv6(forKey: key) as! T
        }
        if T.self == ClickHouseInt128.self {
            return try decodeInt128(forKey: key) as! T
        }
        if T.self == ClickHouseUInt128.self {
            return try decodeUInt128(forKey: key) as! T
        }
        if T.self == ClickHouseInt256.self {
            return try decodeInt256(forKey: key) as! T
        }
        if T.self == ClickHouseUInt256.self {
            return try decodeUInt256(forKey: key) as! T
        }
        if T.self == ClickHouseJSON.self {
            return try decodeJSON(forKey: key) as! T
        }
        if T.self == ClickHouseDecimal.self {
            return try decodeDecimal(forKey: key) as! T
        }
        if T.self == Decimal.self {
            return try decodeFoundationDecimal(forKey: key) as! T
        }
        if T.self == ClickHouseInterval.self {
            return try decodeInterval(forKey: key) as! T
        }
        if T.self == ClickHouseTuple.self {
            return try decodeTuple(forKey: key) as! T
        }
        if T.self == ClickHouseMap.self {
            return try decodeMap(forKey: key) as! T
        }
        if T.self == ClickHouseArrayOfTuple.self {
            return try decodeArrayOfTuple(forKey: key) as! T
        }
        if T.self == ClickHouseVariant.self {
            return try decodeVariant(forKey: key) as! T
        }
        if T.self == ClickHouseDynamic.self {
            return try decodeDynamic(forKey: key) as! T
        }
        if T.self == ClickHouseAggregateState.self {
            return try decodeAggregateState(forKey: key) as! T
        }
        // Route generic Codable decode calls for primitive types to
        // their specific typed overloads. Swift's runtime dispatches a
        // generic `try container.decode(UInt64.self, forKey:)` through
        // this overload rather than the typed `decode(UInt64.Type, ...)`
        // when the calling site has `Value.self` where `Value: Decodable`
        // is only known dynamically (the scalar-wrapper code path). Add
        // explicit primitive routing so single-column SELECTs work
        // through ScalarRowWrapper without requiring the caller to know
        // about it.
        if T.self == Bool.self { return try decode(Bool.self, forKey: key) as! T }
        if T.self == String.self { return try decode(String.self, forKey: key) as! T }
        if T.self == Double.self { return try decode(Double.self, forKey: key) as! T }
        if T.self == Float.self { return try decode(Float.self, forKey: key) as! T }
        if T.self == Int8.self { return try decode(Int8.self, forKey: key) as! T }
        if T.self == Int16.self { return try decode(Int16.self, forKey: key) as! T }
        if T.self == Int32.self { return try decode(Int32.self, forKey: key) as! T }
        if T.self == Int64.self { return try decode(Int64.self, forKey: key) as! T }
        if T.self == UInt8.self { return try decode(UInt8.self, forKey: key) as! T }
        if T.self == UInt16.self { return try decode(UInt16.self, forKey: key) as! T }
        if T.self == UInt32.self { return try decode(UInt32.self, forKey: key) as! T }
        if T.self == UInt64.self { return try decode(UInt64.self, forKey: key) as! T }
        // An Array(T) column over a supported scalar element decodes into
        // the matching native Swift array, so callers can use [String] /
        // [Int64] / [Double] / [Bool] directly instead of the raw-bytes
        // ClickHouseArray escape hatch. Each branch reads the row's element
        // bytes and converts per the column's element discriminator.
        if T.self == [String].self { return try nativeStringArray(forKey: key) as! T }
        if T.self == [Bool].self { return try nativeArray(forKey: key, element: .bool) { (Self.scalar($0) as UInt8) != 0 } as! T }
        if T.self == [Int8].self { return try nativeArray(forKey: key, element: .int8) { Int8(bitPattern: Self.scalar($0)) } as! T }
        // A ClickHouse String column is an arbitrary byte sequence (the
        // generic blob type), so a [UInt8] field reads its exact bytes —
        // lossless where the String overload's UTF-8 decode would replace
        // invalid sequences. An Array(UInt8) column still reads through the
        // native-array path.
        if T.self == [UInt8].self {
            switch try column(forKey: key) {
            case .string(let values): return values[state.rowIndex] as! T
            case .stringValues(let values): return Array(values[state.rowIndex].utf8) as! T
            case .nullableString(let values): return try requirePresent(values[state.rowIndex], key: key) as! T
            default: return try nativeArray(forKey: key, element: .uint8) { Self.scalar($0) as UInt8 } as! T
            }
        }
        if T.self == [Int16].self { return try nativeArray(forKey: key, element: .int16) { Int16(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [UInt16].self { return try nativeArray(forKey: key, element: .uint16) { Self.scalar($0) as UInt16 } as! T }
        if T.self == [Int32].self { return try nativeArray(forKey: key, element: .int32) { Int32(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [UInt32].self { return try nativeArray(forKey: key, element: .uint32) { Self.scalar($0) as UInt32 } as! T }
        if T.self == [Int64].self { return try nativeArray(forKey: key, element: .int64) { Int64(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [UInt64].self { return try nativeArray(forKey: key, element: .uint64) { Self.scalar($0) as UInt64 } as! T }
        if T.self == [Float].self { return try nativeArray(forKey: key, element: .float32) { Float(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [Double].self { return try nativeArray(forKey: key, element: .float64) { Double(bitPattern: Self.scalar($0)) } as! T }
        // Array(Nullable(T)) decodes into [T?]: each row is an array whose
        // elements may individually be NULL. The column carries a per-element
        // null flag lifted from the inner Nullable mask.
        if T.self == [String?].self { return try nullableNativeArray(forKey: key, element: .string) { String(decoding: $0, as: UTF8.self) } as! T }
        if T.self == [Bool?].self { return try nullableNativeArray(forKey: key, element: .bool) { (Self.scalar($0) as UInt8) != 0 } as! T }
        if T.self == [Int8?].self { return try nullableNativeArray(forKey: key, element: .int8) { Int8(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [UInt8?].self { return try nullableNativeArray(forKey: key, element: .uint8) { Self.scalar($0) as UInt8 } as! T }
        if T.self == [Int16?].self { return try nullableNativeArray(forKey: key, element: .int16) { Int16(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [UInt16?].self { return try nullableNativeArray(forKey: key, element: .uint16) { Self.scalar($0) as UInt16 } as! T }
        if T.self == [Int32?].self { return try nullableNativeArray(forKey: key, element: .int32) { Int32(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [UInt32?].self { return try nullableNativeArray(forKey: key, element: .uint32) { Self.scalar($0) as UInt32 } as! T }
        if T.self == [Int64?].self { return try nullableNativeArray(forKey: key, element: .int64) { Int64(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [UInt64?].self { return try nullableNativeArray(forKey: key, element: .uint64) { Self.scalar($0) as UInt64 } as! T }
        if T.self == [Float?].self { return try nullableNativeArray(forKey: key, element: .float32) { Float(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [Double?].self { return try nullableNativeArray(forKey: key, element: .float64) { Double(bitPattern: Self.scalar($0)) } as! T }
        // Array(Array(T)) decodes into [[T]] (nested arrays).
        if T.self == [[String]].self { return try nestedNativeArray(forKey: key, element: .string) { String(decoding: $0, as: UTF8.self) } as! T }
        if T.self == [[Bool]].self { return try nestedNativeArray(forKey: key, element: .bool) { (Self.scalar($0) as UInt8) != 0 } as! T }
        if T.self == [[Int8]].self { return try nestedNativeArray(forKey: key, element: .int8) { Int8(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [[UInt8]].self { return try nestedNativeArray(forKey: key, element: .uint8) { Self.scalar($0) as UInt8 } as! T }
        if T.self == [[Int16]].self { return try nestedNativeArray(forKey: key, element: .int16) { Int16(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [[UInt16]].self { return try nestedNativeArray(forKey: key, element: .uint16) { Self.scalar($0) as UInt16 } as! T }
        if T.self == [[Int32]].self { return try nestedNativeArray(forKey: key, element: .int32) { Int32(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [[UInt32]].self { return try nestedNativeArray(forKey: key, element: .uint32) { Self.scalar($0) as UInt32 } as! T }
        if T.self == [[Int64]].self { return try nestedNativeArray(forKey: key, element: .int64) { Int64(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [[UInt64]].self { return try nestedNativeArray(forKey: key, element: .uint64) { Self.scalar($0) as UInt64 } as! T }
        if T.self == [[Float]].self { return try nestedNativeArray(forKey: key, element: .float32) { Float(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [[Double]].self { return try nestedNativeArray(forKey: key, element: .float64) { Double(bitPattern: Self.scalar($0)) } as! T }
        // Array(Nullable(value-wrapper)) for the fixed-conversion wrappers,
        // mirroring the non-nullable [UUID]/[ClickHouseIPv4]/wide-integer paths.
        if T.self == [UUID?].self { return try nullableNativeArray(forKey: key, element: .uuid) { ClickHouseUUIDWire.uuid(fromWire: $0) } as! T }
        if T.self == [ClickHouseIPv4?].self { return try nullableNativeArray(forKey: key, element: .ipv4) { ClickHouseIPv4(raw: Self.scalar($0)) } as! T }
        if T.self == [ClickHouseIPv6?].self { return try nullableNativeArray(forKey: key, element: .ipv6) { ClickHouseIPv6(bytes: $0) } as! T }
        if T.self == [ClickHouseInt128?].self { return try nullableNativeArray(forKey: key, element: .int128) { ClickHouseInt128(Self.scalar($0)) } as! T }
        if T.self == [ClickHouseUInt128?].self { return try nullableNativeArray(forKey: key, element: .uint128) { ClickHouseUInt128(Self.scalar($0)) } as! T }
        if T.self == [ClickHouseInt256?].self { return try nullableNativeArray(forKey: key, element: .int256) { ClickHouseInt256(littleEndianBytes: $0) } as! T }
        if T.self == [ClickHouseUInt256?].self { return try nullableNativeArray(forKey: key, element: .uint256) { ClickHouseUInt256(littleEndianBytes: $0) } as! T }
        // Array(Nullable(FixedString(N))) carries its width N on the column's
        // element, so it needs its own path rather than the closure-based one.
        if T.self == [ClickHouseFixedString?].self { return try nullableFixedStringArray(forKey: key) as! T }
        if T.self == [ClickHouseDecimal?].self { return try nullableDecimalArray(forKey: key) as! T }
        if T.self == [ClickHouseDateTime64?].self { return try nullableDateTime64Array(forKey: key) as! T }
        if T.self == [Date?].self { return try nullableDateArray(forKey: key) as! T }
        if T.self == [ClickHouseEnum8?].self { return try nullableEnum8Array(forKey: key) as! T }
        if T.self == [ClickHouseEnum16?].self { return try nullableEnum16Array(forKey: key) as! T }
        // Array(FixedString(N)) decodes into [ClickHouseFixedString] (the
        // fixed-width reference-list shape). The element carries a per-column
        // length, so it needs its own path rather than the scalar nativeArray.
        if T.self == [ClickHouseFixedString].self { return try nativeFixedStringArray(forKey: key) as! T }
        // Array(UUID) is wire-identical to Array(FixedString(16)); the
        // 16-byte element is reduced to a UUID by reversing each 8-byte half,
        // the inverse of how ClickHouse stores a UUID's two halves.
        if T.self == [UUID].self { return try nativeArray(forKey: key, element: .uuid) { ClickHouseUUIDWire.uuid(fromWire: $0) } as! T }
        // Array(IPv4) is wire-identical to Array(FixedString(4)) (a 4-byte
        // little-endian integer); Array(IPv6) to Array(FixedString(16)) (16
        // network-order bytes kept as-is).
        if T.self == [ClickHouseIPv4].self { return try nativeArray(forKey: key, element: .ipv4) { ClickHouseIPv4(raw: Self.scalar($0)) } as! T }
        if T.self == [ClickHouseIPv6].self { return try nativeArray(forKey: key, element: .ipv6) { ClickHouseIPv6(bytes: $0) } as! T }
        // Wide integers: 16 little-endian bytes for the 128-bit widths, 32
        // (four little-endian 8-byte limbs) for the 256-bit widths.
        if T.self == [ClickHouseInt128].self { return try nativeArray(forKey: key, element: .int128) { ClickHouseInt128(Self.scalar($0)) } as! T }
        if T.self == [ClickHouseUInt128].self { return try nativeArray(forKey: key, element: .uint128) { ClickHouseUInt128(Self.scalar($0)) } as! T }
        if T.self == [ClickHouseInt256].self { return try nativeArray(forKey: key, element: .int256) { ClickHouseInt256(littleEndianBytes: $0) } as! T }
        if T.self == [ClickHouseUInt256].self { return try nativeArray(forKey: key, element: .uint256) { ClickHouseUInt256(littleEndianBytes: $0) } as! T }
        // Array(DateTime/Date/Date32) decode into [Date]. Only these temporal
        // element types are accepted, so a plain numeric array does not
        // silently masquerade as dates.
        if T.self == [Date].self { return try nativeDateArray(forKey: key) as! T }
        // Array(DateTime64(P)) into [ClickHouseDateTime64] preserves the raw
        // ticks and the column's precision.
        if T.self == [ClickHouseDateTime64].self { return try nativeDateTime64Array(forKey: key) as! T }
        // Array(Decimal(P, S)) into [ClickHouseDecimal]; the element carries
        // the precision and scale and selects the per-element byte width.
        if T.self == [ClickHouseDecimal].self { return try nativeDecimalArray(forKey: key) as! T }
        // Array(Enum8/Enum16) into [ClickHouseEnum8] / [ClickHouseEnum16];
        // the element carries the column's name mapping, each row its ordinal.
        if T.self == [ClickHouseEnum8].self { return try nativeEnum8Array(forKey: key) as! T }
        if T.self == [ClickHouseEnum16].self { return try nativeEnum16Array(forKey: key) as! T }
        // A Map(String, V) column with a String key and a supported scalar
        // value decodes into a native Swift [String: V] (tags/labels and the
        // observability metric maps), so callers avoid the raw-bytes
        // ClickHouseMap escape hatch.
        if T.self == [String: String].self { return try nativeStringKeyedTextMap(forKey: key) as! T }
        if T.self == [String: Int64].self { return try nativeStringKeyedMap(forKey: key, valueElement: .int64) { Int64(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [String: UInt64].self { return try nativeStringKeyedMap(forKey: key, valueElement: .uint64) { Self.scalar($0) as UInt64 } as! T }
        if T.self == [String: Double].self { return try nativeStringKeyedMap(forKey: key, valueElement: .float64) { Double(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [String: Int8].self { return try nativeStringKeyedMap(forKey: key, valueElement: .int8) { Int8(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [String: Int16].self { return try nativeStringKeyedMap(forKey: key, valueElement: .int16) { Int16(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [String: Int32].self { return try nativeStringKeyedMap(forKey: key, valueElement: .int32) { Int32(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [String: UInt8].self { return try nativeStringKeyedMap(forKey: key, valueElement: .uint8) { Self.scalar($0) as UInt8 } as! T }
        if T.self == [String: UInt16].self { return try nativeStringKeyedMap(forKey: key, valueElement: .uint16) { Self.scalar($0) as UInt16 } as! T }
        if T.self == [String: UInt32].self { return try nativeStringKeyedMap(forKey: key, valueElement: .uint32) { Self.scalar($0) as UInt32 } as! T }
        if T.self == [String: Float].self { return try nativeStringKeyedMap(forKey: key, valueElement: .float32) { Float(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [String: Bool].self { return try nativeStringKeyedMap(forKey: key, valueElement: .bool) { (Self.scalar($0) as UInt8) != 0 } as! T }
        if T.self == [String: UUID].self { return try nativeStringKeyedMap(forKey: key, valueElement: .uuid) { ClickHouseUUIDWire.uuid(fromWire: $0) } as! T }
        if T.self == [String: [String]].self { return try nativeStringKeyedArrayMap(forKey: key) as! T }
        if T.self == [String: [Int64]].self { return try nativeStringKeyedScalarArrayMap(forKey: key, valueElement: .int64) { Int64(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [String: [UInt64]].self { return try nativeStringKeyedScalarArrayMap(forKey: key, valueElement: .uint64) { Self.scalar($0) as UInt64 } as! T }
        if T.self == [String: [Double]].self { return try nativeStringKeyedScalarArrayMap(forKey: key, valueElement: .float64) { Double(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [String: [Int32]].self { return try nativeStringKeyedScalarArrayMap(forKey: key, valueElement: .int32) { Int32(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [String: [Float]].self { return try nativeStringKeyedScalarArrayMap(forKey: key, valueElement: .float32) { Float(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [String: [Bool]].self { return try nativeStringKeyedScalarArrayMap(forKey: key, valueElement: .bool) { (Self.scalar($0) as UInt8) != 0 } as! T }
        // Map with integer keys (Map(Int64, V) / Map(UInt64, V)) — an id-keyed map.
        if T.self == [Int64: String].self { return try nativeMap(forKey: key, keyElement: .int64, keyConvert: { Int64(bitPattern: Self.scalar($0)) }, valueElement: .string, valueConvert: { String(decoding: $0, as: UTF8.self) }) as! T }
        if T.self == [UInt64: String].self { return try nativeMap(forKey: key, keyElement: .uint64, keyConvert: { Self.scalar($0) as UInt64 }, valueElement: .string, valueConvert: { String(decoding: $0, as: UTF8.self) }) as! T }
        if T.self == [Int64: Int64].self { return try nativeMap(forKey: key, keyElement: .int64, keyConvert: { Int64(bitPattern: Self.scalar($0)) }, valueElement: .int64, valueConvert: { Int64(bitPattern: Self.scalar($0)) }) as! T }
        if T.self == [UInt64: Int64].self { return try nativeMap(forKey: key, keyElement: .uint64, keyConvert: { Self.scalar($0) as UInt64 }, valueElement: .int64, valueConvert: { Int64(bitPattern: Self.scalar($0)) }) as! T }
        // Map(String, Nullable(V)): a String-keyed map whose values may be NULL.
        if T.self == [String: String?].self { return try nullableStringKeyedMap(forKey: key, valueElement: .string) { String(decoding: $0, as: UTF8.self) } as! T }
        if T.self == [String: Int64?].self { return try nullableStringKeyedMap(forKey: key, valueElement: .int64) { Int64(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [String: UInt64?].self { return try nullableStringKeyedMap(forKey: key, valueElement: .uint64) { Self.scalar($0) as UInt64 } as! T }
        if T.self == [String: Double?].self { return try nullableStringKeyedMap(forKey: key, valueElement: .float64) { Double(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [String: Int8?].self { return try nullableStringKeyedMap(forKey: key, valueElement: .int8) { Int8(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [String: Int16?].self { return try nullableStringKeyedMap(forKey: key, valueElement: .int16) { Int16(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [String: Int32?].self { return try nullableStringKeyedMap(forKey: key, valueElement: .int32) { Int32(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [String: UInt8?].self { return try nullableStringKeyedMap(forKey: key, valueElement: .uint8) { Self.scalar($0) as UInt8 } as! T }
        if T.self == [String: UInt16?].self { return try nullableStringKeyedMap(forKey: key, valueElement: .uint16) { Self.scalar($0) as UInt16 } as! T }
        if T.self == [String: UInt32?].self { return try nullableStringKeyedMap(forKey: key, valueElement: .uint32) { Self.scalar($0) as UInt32 } as! T }
        if T.self == [String: Float?].self { return try nullableStringKeyedMap(forKey: key, valueElement: .float32) { Float(bitPattern: Self.scalar($0)) } as! T }
        if T.self == [String: Bool?].self { return try nullableStringKeyedMap(forKey: key, valueElement: .bool) { (Self.scalar($0) as UInt8) != 0 } as! T }
        if T.self == [Int64: String?].self { return try nullableMap(forKey: key, keyElement: .int64, keyConvert: { Int64(bitPattern: Self.scalar($0)) }, valueElement: .string, valueConvert: { String(decoding: $0, as: UTF8.self) }) as! T }
        if T.self == [UInt64: String?].self { return try nullableMap(forKey: key, keyElement: .uint64, keyConvert: { Self.scalar($0) as UInt64 }, valueElement: .string, valueConvert: { String(decoding: $0, as: UTF8.self) }) as! T }
        if T.self == [Int64: Int64?].self { return try nullableMap(forKey: key, keyElement: .int64, keyConvert: { Int64(bitPattern: Self.scalar($0)) }, valueElement: .int64, valueConvert: { Int64(bitPattern: Self.scalar($0)) }) as! T }
        // An explicitly-requested Optional decode target (the nullable
        // scalar path: scalar(as: Int32?.self) decodes via
        // container.decode(Optional<T>.self)) delegates to decodeIfPresent,
        // which already handles every nullable column. Without this an
        // Optional target would be rejected even though its non-Optional
        // and decodeIfPresent forms both work.
        if let optionalType = T.self as? ClickHouseOptionalDecoding.Type {
            return try optionalType.clickHouseDecodeNullable(from: self, forKey: key) as! T
        }
        // Delegate any remaining target to its own init(from:) over a
        // single-value view of the column. This covers the idiomatic
        // RawRepresentable enum (a status / category column maps to a Swift
        // enum) and any custom type that decodes from one value: the type's
        // synthesized decoder reads its RawValue (Int32, String, …) through
        // the single-value container, which forwards to this container's
        // typed decode for the same key.
        guard case .found = state.slot(for: key.stringValue) else { throw missing(key) }
        let resolvedColumn = try column(forKey: key)
        if case .tuple(let subColumns, let names) = resolvedColumn {
            return try decodeTupleStruct(type, subColumns: subColumns, names: names, key: key)
        }
        if case .arrayOfTuple(let elementValues, let elements, let names) = resolvedColumn {
            return try decodeArrayOfTupleStructs(type, elementValues: elementValues, elements: elements, names: names, key: key)
        }
        return try T(from: ClickHouseColumnValueDecoder(container: self, key: key, codingPath: codingPath + [key]))
    }

    // A named Tuple column carries one sub-column per element. Exposing those
    // sub-columns as a nested keyed container at the current row lets a Tuple
    // decode straight into a nested Swift struct whose properties match the
    // element names, rather than forcing callers onto the raw ClickHouseTuple.
    private func decodeTupleStruct<T: Decodable>(_ type: T.Type, subColumns: [ClickHouseTypedColumn], names: [String], key: Key) throws -> T {
        let named = zip(names, subColumns).map { ClickHouseNamedColumn(name: $0, column: $1) }
        let nestedState = ClickHouseColumnarDecoderState(columns: named)
        nestedState.rowIndex = state.rowIndex
        return try T(from: ClickHouseColumnarDecoder(state: nestedState, codingPath: codingPath + [key]))
    }

    // An Array(Tuple(...)) cell carries one value per array element in each of
    // its tuple sub-columns. Re-row those element values into a mini block whose
    // named columns mirror the tuple fields, then decode the array via an
    // unkeyed container so the list lands as [Struct] with each element a row.
    // Works for any tuple arity: one sub-column in elementValues per field.
    private func decodeArrayOfTupleStructs<T: Decodable>(
        _ type: T.Type,
        elementValues: [[[[UInt8]]]],
        elements: [ClickHouseArrayElementType],
        names: [String],
        key: Key
    ) throws -> T {
        let row = state.rowIndex
        let elementCount = elementValues.isEmpty ? 0 : elementValues[0][row].count
        var perElementRows: [[[UInt8]]] = []
        perElementRows.reserveCapacity(elementCount)
        for index in 0..<elementCount {
            var tupleRow: [[UInt8]] = []
            tupleRow.reserveCapacity(elementValues.count)
            for elementColumn in elementValues {
                tupleRow.append(elementColumn[row][index])
            }
            perElementRows.append(tupleRow)
        }
        let columns = ClickHouseTupleColumnBuilder.columns(rows: perElementRows, elements: elements)
        let named = zip(names, columns).map { ClickHouseNamedColumn(name: $0, column: $1) }
        let nestedState = ClickHouseColumnarDecoderState(columns: named)
        let decoder = ClickHouseArrayOfTupleDecoder(state: nestedState, total: elementCount, codingPath: codingPath + [key])
        return try T(from: decoder)
    }

    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? {
        try wrapPresent(forKey: key) { try decode(Bool.self, forKey: key) }
    }
    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? {
        try wrapPresent(forKey: key) { try decode(String.self, forKey: key) }
    }
    func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? {
        try wrapPresent(forKey: key) { try decode(Double.self, forKey: key) }
    }
    func decodeIfPresent(_ type: Float.Type, forKey key: Key) throws -> Float? {
        try wrapPresent(forKey: key) { try decode(Float.self, forKey: key) }
    }
    func decodeIfPresent(_ type: Int8.Type, forKey key: Key) throws -> Int8? {
        try wrapPresent(forKey: key) { try decode(Int8.self, forKey: key) }
    }
    func decodeIfPresent(_ type: Int16.Type, forKey key: Key) throws -> Int16? {
        try wrapPresent(forKey: key) { try decode(Int16.self, forKey: key) }
    }
    func decodeIfPresent(_ type: Int32.Type, forKey key: Key) throws -> Int32? {
        try wrapPresent(forKey: key) { try decode(Int32.self, forKey: key) }
    }
    func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? {
        try wrapPresent(forKey: key) { try decode(Int64.self, forKey: key) }
    }
    func decodeIfPresent(_ type: UInt8.Type, forKey key: Key) throws -> UInt8? {
        try wrapPresent(forKey: key) { try decode(UInt8.self, forKey: key) }
    }
    func decodeIfPresent(_ type: UInt16.Type, forKey key: Key) throws -> UInt16? {
        try wrapPresent(forKey: key) { try decode(UInt16.self, forKey: key) }
    }
    func decodeIfPresent(_ type: UInt32.Type, forKey key: Key) throws -> UInt32? {
        try wrapPresent(forKey: key) { try decode(UInt32.self, forKey: key) }
    }
    func decodeIfPresent(_ type: UInt64.Type, forKey key: Key) throws -> UInt64? {
        try wrapPresent(forKey: key) { try decode(UInt64.self, forKey: key) }
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        if T.self == Date.self {
            return try wrapPresent(forKey: key) { try decodeDate(forKey: key) } as! T?
        }
        if T.self == UUID.self {
            return try wrapPresent(forKey: key) { try decodeUUID(forKey: key) } as! T?
        }
        return try wrapPresent(forKey: key) { try decode(T.self, forKey: key) }
    }

    func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
        throw DecodingError.dataCorrupted(.init(
            codingPath: codingPath + [key],
            debugDescription: "Nested keyed containers are not supported."
        ))
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        throw DecodingError.dataCorrupted(.init(
            codingPath: codingPath + [key],
            debugDescription: "Nested unkeyed containers are not supported."
        ))
    }

    func superDecoder() throws -> Decoder {
        throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "superDecoder is not supported."))
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        throw DecodingError.dataCorrupted(.init(codingPath: codingPath + [key], debugDescription: "superDecoder(forKey:) is not supported."))
    }

    private func column(forKey key: Key) throws -> ClickHouseTypedColumn {
        if state.hintedSlot >= 0 {
            let slot = state.hintedSlot
            state.hintedSlot = -1
            return state.columns[slot].column
        }
        guard case .found(let slot) = state.slot(for: key.stringValue) else {
            throw missing(key)
        }
        return state.columns[slot].column
    }

    private func isNullAt(slot: Int) -> Bool {
        switch state.columns[slot].column {
        case .nullableBool(let v): v[state.rowIndex].isAbsent
        case .nullableString(let v): v[state.rowIndex].isAbsent
        case .nullableInt8(let v): v[state.rowIndex].isAbsent
        case .nullableInt16(let v): v[state.rowIndex].isAbsent
        case .nullableInt32(let v): v[state.rowIndex].isAbsent
        case .nullableInt64(let v): v[state.rowIndex].isAbsent
        case .nullableUInt8(let v): v[state.rowIndex].isAbsent
        case .nullableUInt16(let v): v[state.rowIndex].isAbsent
        case .nullableUInt32(let v): v[state.rowIndex].isAbsent
        case .nullableUInt64(let v): v[state.rowIndex].isAbsent
        case .nullableFloat32(let v): v[state.rowIndex].isAbsent
        case .nullableFloat64(let v): v[state.rowIndex].isAbsent
        case .nullableDateTime(let v): v[state.rowIndex].isAbsent
        case .nullableUUID(let v): v[state.rowIndex].isAbsent
        case .nullable(let mask, _): mask[state.rowIndex]
        default: false
        }
    }

    private func decodeDate(forKey key: Key) throws -> Date {
        // nonNullColumn unwraps a Nullable(DateTime64/Date/Date32) carried as
        // the generic .nullable wrapper. Every temporal column denotes an
        // absolute instant, so all map onto a Swift Date: DateTime64 ticks
        // scale by the precision; Date/Date32 days scale by seconds-per-day.
        switch try nonNullColumn(forKey: key, expected: "Date") {
        case .dateTime(let values): return values[state.rowIndex]
        case .nullableDateTime(let values): return try requirePresent(values[state.rowIndex], key: key)
        case .dateTime64(let values, let precision):
            return Date(timeIntervalSince1970: Double(values[state.rowIndex]) / pow(10.0, Double(precision)))
        case .date(let values):
            return Date(timeIntervalSince1970: Double(values[state.rowIndex]) * 86_400)
        case .date32(let values):
            return Date(timeIntervalSince1970: Double(values[state.rowIndex]) * 86_400)
        default: throw typeMismatch(key, expected: "Date")
        }
    }

    private func decodeUUID(forKey key: Key) throws -> UUID {
        switch try column(forKey: key) {
        case .uuid(let values): return values[state.rowIndex]
        case .nullableUUID(let values): return try requirePresent(values[state.rowIndex], key: key)
        default: throw typeMismatch(key, expected: "UUID")
        }
    }

    private func decodeDateTime64(forKey key: Key) throws -> ClickHouseDateTime64 {
        switch try nonNullColumn(forKey: key, expected: "DateTime64") {
        case .dateTime64(let values, let precision):
            return ClickHouseDateTime64(ticks: values[state.rowIndex], precision: precision)
        default: throw typeMismatch(key, expected: "DateTime64")
        }
    }

    private func decodeFixedString(forKey key: Key) throws -> ClickHouseFixedString {
        switch try nonNullColumn(forKey: key, expected: "FixedString") {
        case .fixedString(let values, let length):
            return ClickHouseFixedString(bytes: values[state.rowIndex], length: length)
        case .lowCardinality(let values, .fixedString(let length)):
            return ClickHouseFixedString(bytes: values[state.rowIndex], length: length)
        default: throw typeMismatch(key, expected: "FixedString")
        }
    }

    private func decodeEnum8(forKey key: Key) throws -> ClickHouseEnum8 {
        switch try nonNullColumn(forKey: key, expected: "Enum8") {
        case .enum8(let values, let mapping):
            return ClickHouseEnum8(value: values[state.rowIndex], mapping: mapping)
        default: throw typeMismatch(key, expected: "Enum8")
        }
    }

    private func decodeEnum16(forKey key: Key) throws -> ClickHouseEnum16 {
        switch try nonNullColumn(forKey: key, expected: "Enum16") {
        case .enum16(let values, let mapping):
            return ClickHouseEnum16(value: values[state.rowIndex], mapping: mapping)
        default: throw typeMismatch(key, expected: "Enum16")
        }
    }

    private func decodeLowCardinality(forKey key: Key) throws -> ClickHouseLowCardinality {
        switch try nonNullColumn(forKey: key, expected: "LowCardinality") {
        case .lowCardinality(let values, let inner):
            return ClickHouseLowCardinality(inner: inner, value: values[state.rowIndex])
        default: throw typeMismatch(key, expected: "LowCardinality")
        }
    }

    private func decodeArray(forKey key: Key) throws -> ClickHouseArray {
        switch try nonNullColumn(forKey: key, expected: "Array") {
        case .array(let values, let element):
            return ClickHouseArray(element: element, elements: values[state.rowIndex])
        default: throw typeMismatch(key, expected: "Array")
        }
    }

    // A [String] field accepts both Array(String) and Array(FixedString(N)): the
    // FixedString element is read as trimmed text, the same interpretation the
    // scalar String decode and the string accessors apply, so an Array of
    // fixed-width identifier columns is usable without modeling the element as
    // ClickHouseFixedString.
    private func nativeStringArray(forKey key: Key) throws -> [String] {
        switch try nonNullColumn(forKey: key, expected: "Array(String)") {
        case .array(let values, .string): return values[state.rowIndex].map { ClickHouseUTF8.decode($0) }
        case .array(let values, .fixedString(let length)): return values[state.rowIndex].map { ClickHouseFixedString(bytes: $0, length: length).text }
        case .array(let values, .enum8(let mapping)): return try values[state.rowIndex].map { try enumName(Int16(Self.scalar($0) as Int8), mapping: mapping, key: key) }
        case .array(let values, .enum16(let mapping)): return try values[state.rowIndex].map { try enumName(Self.scalar($0) as Int16, mapping: mapping, key: key) }
        default: throw typeMismatch(key, expected: "Array(String)")
        }
    }

    private func nativeArray<Element>(
        forKey key: Key,
        element expected: ClickHouseArrayElementType,
        _ convert: ([UInt8]) -> Element
    ) throws -> [Element] {
        switch try nonNullColumn(forKey: key, expected: "Array(\(expected.typeName))") {
        case .array(let values, let element):
            guard element == expected else {
                throw typeMismatch(key, expected: "Array(\(expected.typeName))")
            }
            return values[state.rowIndex].map(convert)
        default:
            throw typeMismatch(key, expected: "Array(\(expected.typeName))")
        }
    }

    private func nullableNativeArray<Element>(
        forKey key: Key,
        element expected: ClickHouseArrayElementType,
        _ convert: ([UInt8]) -> Element
    ) throws -> [Element?] {
        let label = "Array(Nullable(\(expected.typeName)))"
        switch try nonNullColumn(forKey: key, expected: label) {
        case .arrayOfNullable(let perRow, let element):
            guard element == expected else {
                throw typeMismatch(key, expected: label)
            }
            return perRow[state.rowIndex].map { Self.mapNullableElement($0, convert) }
        default:
            throw typeMismatch(key, expected: label)
        }
    }

    private static func mapNullableElement<Element>(_ value: ClickHouseNullable<[UInt8]>, _ convert: ([UInt8]) -> Element) -> Element? {
        switch value {
        case .present(let bytes): return convert(bytes)
        case .absent: return nil
        }
    }

    private func nestedNativeArray<Element>(
        forKey key: Key,
        element expected: ClickHouseArrayElementType,
        _ convert: ([UInt8]) -> Element
    ) throws -> [[Element]] {
        let label = "Array(Array(\(expected.typeName)))"
        switch try nonNullColumn(forKey: key, expected: label) {
        case .nestedArray(let perRow, let element):
            guard element == expected else {
                throw typeMismatch(key, expected: label)
            }
            return perRow[state.rowIndex].map { innerArray in innerArray.map(convert) }
        default:
            throw typeMismatch(key, expected: label)
        }
    }

    // A [String: String] field accepts a Map with a String or FixedString(N)
    // value: the FixedString value is read as trimmed text, the same
    // interpretation the scalar String decode and the array path apply, so a map
    // of fixed-width identifier values is usable without modeling the value as
    // ClickHouseFixedString.
    private func nativeStringKeyedTextMap(forKey key: Key) throws -> [String: String] {
        switch try nonNullColumn(forKey: key, expected: "Map(String, String)") {
        case .map(let keys, let values, .string, .string):
            let pairs = zip(keys[state.rowIndex].map { ClickHouseUTF8.decode($0) }, values[state.rowIndex].map { ClickHouseUTF8.decode($0) })
            return Dictionary(pairs, uniquingKeysWith: { _, latest in latest })
        case .map(let keys, let values, .string, .fixedString(let length)):
            let pairs = zip(keys[state.rowIndex].map { ClickHouseUTF8.decode($0) }, values[state.rowIndex].map { ClickHouseFixedString(bytes: $0, length: length).text })
            return Dictionary(pairs, uniquingKeysWith: { _, latest in latest })
        default:
            throw typeMismatch(key, expected: "Map(String, String)")
        }
    }

    private func nativeStringKeyedArrayMap(forKey key: Key) throws -> [String: [String]] {
        switch try nonNullColumn(forKey: key, expected: "Map(String, Array(String))") {
        case .mapWithArrayValues(let keys, let values, .string, .string):
            return Self.stringKeyedArrays(keys: keys[state.rowIndex], values: values[state.rowIndex]) { ClickHouseUTF8.decode($0) }
        case .mapWithArrayValues(let keys, let values, .string, .fixedString(let length)):
            return Self.stringKeyedArrays(keys: keys[state.rowIndex], values: values[state.rowIndex]) { ClickHouseFixedString(bytes: $0, length: length).text }
        default:
            throw typeMismatch(key, expected: "Map(String, Array(String))")
        }
    }

    private static func stringKeyedArrays(keys: [[UInt8]], values: [[[UInt8]]], _ element: ([UInt8]) -> String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        result.reserveCapacity(keys.count)
        for index in keys.indices {
            result[ClickHouseUTF8.decode(keys[index])] = values[index].map(element)
        }
        return result
    }

    private func nativeStringKeyedScalarArrayMap<V>(forKey key: Key, valueElement expected: ClickHouseArrayElementType, _ convert: ([UInt8]) -> V) throws -> [String: [V]] {
        let label = "Map(String, Array(\(expected.typeName)))"
        switch try nonNullColumn(forKey: key, expected: label) {
        case .mapWithArrayValues(let keys, let values, .string, let valueElement):
            guard valueElement == expected else { throw typeMismatch(key, expected: label) }
            let rowKeys = keys[state.rowIndex]
            let rowValues = values[state.rowIndex]
            var result: [String: [V]] = [:]
            result.reserveCapacity(rowKeys.count)
            for index in rowKeys.indices {
                result[ClickHouseUTF8.decode(rowKeys[index])] = rowValues[index].map(convert)
            }
            return result
        default:
            throw typeMismatch(key, expected: label)
        }
    }

    private func nativeStringKeyedMap<V>(
        forKey key: Key,
        valueElement expected: ClickHouseArrayElementType,
        _ convert: ([UInt8]) -> V
    ) throws -> [String: V] {
        try nativeMap(forKey: key, keyElement: .string, keyConvert: { String(decoding: $0, as: UTF8.self) }, valueElement: expected, valueConvert: convert)
    }

    private func nativeMap<K: Hashable, V>(
        forKey key: Key,
        keyElement: ClickHouseArrayElementType,
        keyConvert: ([UInt8]) -> K,
        valueElement: ClickHouseArrayElementType,
        valueConvert: ([UInt8]) -> V
    ) throws -> [K: V] {
        let label = "Map(\(keyElement.typeName), \(valueElement.typeName))"
        switch try nonNullColumn(forKey: key, expected: label) {
        case .map(let keys, let values, let kElement, let vElement):
            guard kElement == keyElement, vElement == valueElement else {
                throw typeMismatch(key, expected: label)
            }
            let rowKeys = keys[state.rowIndex].map(keyConvert)
            let rowValues = values[state.rowIndex].map(valueConvert)
            return Dictionary(zip(rowKeys, rowValues), uniquingKeysWith: { _, latest in latest })
        default:
            throw typeMismatch(key, expected: label)
        }
    }

    private func nullableStringKeyedMap<V>(
        forKey key: Key,
        valueElement expected: ClickHouseArrayElementType,
        _ convert: ([UInt8]) -> V
    ) throws -> [String: V?] {
        try nullableMap(forKey: key, keyElement: .string, keyConvert: { String(decoding: $0, as: UTF8.self) }, valueElement: expected, valueConvert: convert)
    }

    private func nullableMap<K: Hashable, V>(
        forKey key: Key,
        keyElement: ClickHouseArrayElementType,
        keyConvert: ([UInt8]) -> K,
        valueElement: ClickHouseArrayElementType,
        valueConvert: ([UInt8]) -> V
    ) throws -> [K: V?] {
        let label = "Map(\(keyElement.typeName), Nullable(\(valueElement.typeName)))"
        switch try nonNullColumn(forKey: key, expected: label) {
        case .mapWithNullableValues(let keys, let values, let kElement, let vElement):
            guard kElement == keyElement, vElement == valueElement else {
                throw typeMismatch(key, expected: label)
            }
            let rowKeys = keys[state.rowIndex].map(keyConvert)
            let rowValues: [V?] = values[state.rowIndex].map { Self.mapNullableElement($0, valueConvert) }
            return Dictionary(zip(rowKeys, rowValues), uniquingKeysWith: { _, latest in latest })
        default:
            throw typeMismatch(key, expected: label)
        }
    }

    private func nativeDateArray(forKey key: Key) throws -> [Date] {
        switch try nonNullColumn(forKey: key, expected: "Array(DateTime)") {
        case .array(let values, let element):
            let row = values[state.rowIndex]
            switch element {
            case .dateTime: return row.map { Date(timeIntervalSince1970: TimeInterval(Self.scalar($0) as UInt32)) }
            case .date: return row.map { Date(timeIntervalSince1970: TimeInterval(Self.scalar($0) as UInt16) * 86_400) }
            case .date32: return row.map { Date(timeIntervalSince1970: TimeInterval(Int32(bitPattern: Self.scalar($0))) * 86_400) }
            case .dateTime64(let precision): return row.map { Date(timeIntervalSince1970: Double(Int64(bitPattern: Self.scalar($0))) / pow(10.0, Double(precision))) }
            default: throw typeMismatch(key, expected: "Array(DateTime), Array(Date), Array(Date32) or Array(DateTime64)")
            }
        default:
            throw typeMismatch(key, expected: "Array(DateTime)")
        }
    }

    private func nativeEnum8Array(forKey key: Key) throws -> [ClickHouseEnum8] {
        switch try nonNullColumn(forKey: key, expected: "Array(Enum8)") {
        case .array(let values, let element):
            guard case .enum8(let mapping) = element else {
                throw typeMismatch(key, expected: "Array(Enum8)")
            }
            return values[state.rowIndex].map { ClickHouseEnum8(value: Int8(bitPattern: Self.scalar($0)), mapping: mapping) }
        default:
            throw typeMismatch(key, expected: "Array(Enum8)")
        }
    }

    private func nativeEnum16Array(forKey key: Key) throws -> [ClickHouseEnum16] {
        switch try nonNullColumn(forKey: key, expected: "Array(Enum16)") {
        case .array(let values, let element):
            guard case .enum16(let mapping) = element else {
                throw typeMismatch(key, expected: "Array(Enum16)")
            }
            return values[state.rowIndex].map { ClickHouseEnum16(value: Int16(bitPattern: Self.scalar($0)), mapping: mapping) }
        default:
            throw typeMismatch(key, expected: "Array(Enum16)")
        }
    }

    private func nativeDecimalArray(forKey key: Key) throws -> [ClickHouseDecimal] {
        switch try nonNullColumn(forKey: key, expected: "Array(Decimal)") {
        case .array(let values, let element):
            guard case .decimal(let precision, let scale) = element else {
                throw typeMismatch(key, expected: "Array(Decimal)")
            }
            return values[state.rowIndex].map { ClickHouseDecimal(littleEndianBytes: $0, precision: precision, scale: scale) }
        default:
            throw typeMismatch(key, expected: "Array(Decimal)")
        }
    }

    private func nativeDateTime64Array(forKey key: Key) throws -> [ClickHouseDateTime64] {
        switch try nonNullColumn(forKey: key, expected: "Array(DateTime64)") {
        case .array(let values, let element):
            guard case .dateTime64(let precision) = element else {
                throw typeMismatch(key, expected: "Array(DateTime64)")
            }
            return values[state.rowIndex].map { ClickHouseDateTime64(ticks: Int64(bitPattern: Self.scalar($0)), precision: precision) }
        default:
            throw typeMismatch(key, expected: "Array(DateTime64)")
        }
    }

    private func nativeFixedStringArray(forKey key: Key) throws -> [ClickHouseFixedString] {
        switch try nonNullColumn(forKey: key, expected: "Array(FixedString)") {
        case .array(let values, let element):
            guard case .fixedString(let length) = element else {
                throw typeMismatch(key, expected: "Array(FixedString)")
            }
            return values[state.rowIndex].map { ClickHouseFixedString(bytes: $0, length: length) }
        default:
            throw typeMismatch(key, expected: "Array(FixedString)")
        }
    }

    private func nullableFixedStringArray(forKey key: Key) throws -> [ClickHouseFixedString?] {
        switch try nonNullColumn(forKey: key, expected: "Array(Nullable(FixedString))") {
        case .arrayOfNullable(let perRow, let element):
            guard case .fixedString(let length) = element else {
                throw typeMismatch(key, expected: "Array(Nullable(FixedString))")
            }
            return perRow[state.rowIndex].map { (entry: ClickHouseNullable<[UInt8]>) -> ClickHouseFixedString? in
                switch entry {
                case .present(let bytes): return ClickHouseFixedString(bytes: bytes, length: length)
                case .absent: return nil
                }
            }
        default:
            throw typeMismatch(key, expected: "Array(Nullable(FixedString))")
        }
    }

    private func nullableDecimalArray(forKey key: Key) throws -> [ClickHouseDecimal?] {
        switch try nonNullColumn(forKey: key, expected: "Array(Nullable(Decimal))") {
        case .arrayOfNullable(let perRow, let element):
            guard case .decimal(let precision, let scale) = element else {
                throw typeMismatch(key, expected: "Array(Nullable(Decimal))")
            }
            return perRow[state.rowIndex].map { (entry: ClickHouseNullable<[UInt8]>) -> ClickHouseDecimal? in
                switch entry {
                case .present(let bytes): return ClickHouseDecimal(littleEndianBytes: bytes, precision: precision, scale: scale)
                case .absent: return nil
                }
            }
        default:
            throw typeMismatch(key, expected: "Array(Nullable(Decimal))")
        }
    }

    private func nullableDateTime64Array(forKey key: Key) throws -> [ClickHouseDateTime64?] {
        switch try nonNullColumn(forKey: key, expected: "Array(Nullable(DateTime64))") {
        case .arrayOfNullable(let perRow, let element):
            guard case .dateTime64(let precision) = element else {
                throw typeMismatch(key, expected: "Array(Nullable(DateTime64))")
            }
            return perRow[state.rowIndex].map { (entry: ClickHouseNullable<[UInt8]>) -> ClickHouseDateTime64? in
                switch entry {
                case .present(let bytes): return ClickHouseDateTime64(ticks: Int64(bitPattern: Self.scalar(bytes)), precision: precision)
                case .absent: return nil
                }
            }
        default:
            throw typeMismatch(key, expected: "Array(Nullable(DateTime64))")
        }
    }

    private func nullableEnum8Array(forKey key: Key) throws -> [ClickHouseEnum8?] {
        switch try nonNullColumn(forKey: key, expected: "Array(Nullable(Enum8))") {
        case .arrayOfNullable(let perRow, let element):
            guard case .enum8(let mapping) = element else {
                throw typeMismatch(key, expected: "Array(Nullable(Enum8))")
            }
            return perRow[state.rowIndex].map { (entry: ClickHouseNullable<[UInt8]>) -> ClickHouseEnum8? in
                switch entry {
                case .present(let bytes): return ClickHouseEnum8(value: Int8(bitPattern: Self.scalar(bytes)), mapping: mapping)
                case .absent: return nil
                }
            }
        default:
            throw typeMismatch(key, expected: "Array(Nullable(Enum8))")
        }
    }

    private func nullableEnum16Array(forKey key: Key) throws -> [ClickHouseEnum16?] {
        switch try nonNullColumn(forKey: key, expected: "Array(Nullable(Enum16))") {
        case .arrayOfNullable(let perRow, let element):
            guard case .enum16(let mapping) = element else {
                throw typeMismatch(key, expected: "Array(Nullable(Enum16))")
            }
            return perRow[state.rowIndex].map { (entry: ClickHouseNullable<[UInt8]>) -> ClickHouseEnum16? in
                switch entry {
                case .present(let bytes): return ClickHouseEnum16(value: Int16(bitPattern: Self.scalar(bytes)), mapping: mapping)
                case .absent: return nil
                }
            }
        default:
            throw typeMismatch(key, expected: "Array(Nullable(Enum16))")
        }
    }

    // Array(Nullable(DateTime/Date/Date32/DateTime64)) into [Date?]. The inner
    // temporal element decides how each present value's bytes map to an
    // instant, mirroring the non-nullable nativeDateArray.
    private func nullableDateArray(forKey key: Key) throws -> [Date?] {
        switch try nonNullColumn(forKey: key, expected: "Array(Nullable(DateTime))") {
        case .arrayOfNullable(let perRow, let element):
            let row = perRow[state.rowIndex]
            switch element {
            case .dateTime:
                return row.map { entry in Self.mapNullableElement(entry) { Date(timeIntervalSince1970: TimeInterval(Self.scalar($0) as UInt32)) } }
            case .date:
                return row.map { entry in Self.mapNullableElement(entry) { Date(timeIntervalSince1970: TimeInterval(Self.scalar($0) as UInt16) * 86_400) } }
            case .date32:
                return row.map { entry in Self.mapNullableElement(entry) { Date(timeIntervalSince1970: TimeInterval(Int32(bitPattern: Self.scalar($0))) * 86_400) } }
            case .dateTime64(let precision):
                return row.map { entry in Self.mapNullableElement(entry) { Date(timeIntervalSince1970: Double(Int64(bitPattern: Self.scalar($0))) / pow(10.0, Double(precision))) } }
            default:
                throw typeMismatch(key, expected: "Array(Nullable(DateTime/Date/Date32/DateTime64))")
            }
        default:
            throw typeMismatch(key, expected: "Array(Nullable(DateTime))")
        }
    }

    private static func scalar<Value: FixedWidthInteger>(_ bytes: [UInt8]) -> Value {
        var value: Value = 0
        let width = Swift.min(MemoryLayout<Value>.size, bytes.count)
        for index in 0..<width {
            value |= Value(bytes[index]) << (8 * index)
        }
        return value
    }

    private func decodeDate32(forKey key: Key) throws -> ClickHouseDate32 {
        switch try nonNullColumn(forKey: key, expected: "Date32") {
        case .date32(let values): return ClickHouseDate32(days: values[state.rowIndex])
        default: throw typeMismatch(key, expected: "Date32")
        }
    }

    private func decodeBFloat16(forKey key: Key) throws -> ClickHouseBFloat16 {
        switch try nonNullColumn(forKey: key, expected: "BFloat16") {
        case .bfloat16(let values): return ClickHouseBFloat16(rawBits: values[state.rowIndex])
        default: throw typeMismatch(key, expected: "BFloat16")
        }
    }

    private func decodeInterval(forKey key: Key) throws -> ClickHouseInterval {
        switch try nonNullColumn(forKey: key, expected: "Interval") {
        case .interval(let values, let kind):
            return ClickHouseInterval(value: values[state.rowIndex], kind: kind)
        default: throw typeMismatch(key, expected: "Interval")
        }
    }

    private func decodeClickHouseDate(forKey key: Key) throws -> ClickHouseDate {
        switch try nonNullColumn(forKey: key, expected: "Date") {
        case .date(let values): return ClickHouseDate(days: values[state.rowIndex])
        default: throw typeMismatch(key, expected: "Date")
        }
    }

    private func decodeTime(forKey key: Key) throws -> ClickHouseTime {
        switch try nonNullColumn(forKey: key, expected: "Time") {
        case .time(let values): return ClickHouseTime(seconds: values[state.rowIndex])
        default: throw typeMismatch(key, expected: "Time")
        }
    }

    private func decodeTime64(forKey key: Key) throws -> ClickHouseTime64 {
        switch try nonNullColumn(forKey: key, expected: "Time64") {
        case .time64(let values, let precision):
            return ClickHouseTime64(ticks: values[state.rowIndex], precision: precision)
        default: throw typeMismatch(key, expected: "Time64")
        }
    }

    private func decodeIPv4(forKey key: Key) throws -> ClickHouseIPv4 {
        switch try nonNullColumn(forKey: key, expected: "IPv4") {
        case .ipv4(let values): return ClickHouseIPv4(raw: values[state.rowIndex])
        default: throw typeMismatch(key, expected: "IPv4")
        }
    }

    private func decodeIPv6(forKey key: Key) throws -> ClickHouseIPv6 {
        switch try nonNullColumn(forKey: key, expected: "IPv6") {
        case .ipv6(let values): return ClickHouseIPv6(bytes: values[state.rowIndex])
        default: throw typeMismatch(key, expected: "IPv6")
        }
    }

    private func decodeInt128(forKey key: Key) throws -> ClickHouseInt128 {
        switch try nonNullColumn(forKey: key, expected: "Int128") {
        case .int128(let values): return ClickHouseInt128(values[state.rowIndex])
        default: throw typeMismatch(key, expected: "Int128")
        }
    }

    private func decodeUInt128(forKey key: Key) throws -> ClickHouseUInt128 {
        switch try nonNullColumn(forKey: key, expected: "UInt128") {
        case .uint128(let values): return ClickHouseUInt128(values[state.rowIndex])
        default: throw typeMismatch(key, expected: "UInt128")
        }
    }

    private func decodeInt256(forKey key: Key) throws -> ClickHouseInt256 {
        switch try nonNullColumn(forKey: key, expected: "Int256") {
        case .int256(let values): return values[state.rowIndex]
        default: throw typeMismatch(key, expected: "Int256")
        }
    }

    private func decodeUInt256(forKey key: Key) throws -> ClickHouseUInt256 {
        switch try nonNullColumn(forKey: key, expected: "UInt256") {
        case .uint256(let values): return values[state.rowIndex]
        default: throw typeMismatch(key, expected: "UInt256")
        }
    }

    private func decodeTuple(forKey key: Key) throws -> ClickHouseTuple {
        switch try nonNullColumn(forKey: key, expected: "Tuple") {
        case .tuple(let columns, _):
            let elements = try ClickHouseTupleColumnBuilder.elementTypes(of: columns)
            let values = ClickHouseTupleColumnBuilder.rawElementBytes(columns: columns, rowIndex: state.rowIndex)
            return ClickHouseTuple(elements: elements, values: values)
        default: throw typeMismatch(key, expected: "Tuple")
        }
    }

    private func decodeMap(forKey key: Key) throws -> ClickHouseMap {
        switch try nonNullColumn(forKey: key, expected: "Map") {
        case .map(let keys, let values, let keyElement, let valueElement):
            return ClickHouseMap(
                keyElement: keyElement,
                valueElement: valueElement,
                keys: keys[state.rowIndex],
                values: values[state.rowIndex]
            )
        default: throw typeMismatch(key, expected: "Map")
        }
    }

    private func decodeArrayOfTuple(forKey key: Key) throws -> ClickHouseArrayOfTuple {
        switch try nonNullColumn(forKey: key, expected: "Array(Tuple)") {
        case .arrayOfTuple(let elementValues, let elements, _):
            guard elements.count == 2 else {
                throw DecodingError.typeMismatch(ClickHouseArrayOfTuple.self, .init(
                    codingPath: codingPath,
                    debugDescription: "ClickHouseArrayOfTuple holds 2 tuple fields; this column has \(elements.count). Decode it into an array of a Decodable struct with one property per field instead."
                ))
            }
            return ClickHouseArrayOfTuple(
                firstElement: elements[0],
                secondElement: elements[1],
                firstValues: elementValues[0][state.rowIndex],
                secondValues: elementValues[1][state.rowIndex]
            )
        default: throw typeMismatch(key, expected: "Array(Tuple)")
        }
    }

    private func decodeVariant(forKey key: Key) throws -> ClickHouseVariant {
        switch try nonNullColumn(forKey: key, expected: "Variant") {
        case .variant(let members, let discriminators, let values):
            let discriminator = discriminators[state.rowIndex]
            if discriminator == 255 {
                return ClickHouseVariant(members: members, value: .null)
            }
            try requireMemberInRange(discriminator, memberCount: members.count, kind: "Variant", stage: "decoder.variant")
            let value = try ClickHouseVariantMember.value(element: members[Int(discriminator)], bytes: values[state.rowIndex])
            return ClickHouseVariant(members: members, value: value)
        default: throw typeMismatch(key, expected: "Variant")
        }
    }

    private func decodeDynamic(forKey key: Key) throws -> ClickHouseDynamic {
        switch try nonNullColumn(forKey: key, expected: "Dynamic") {
        case .dynamic(let members, let discriminators, let values):
            let discriminator = discriminators[state.rowIndex]
            if discriminator == 255 {
                return ClickHouseDynamic(.null)
            }
            try requireMemberInRange(discriminator, memberCount: members.count, kind: "Dynamic", stage: "decoder.dynamic")
            let value = try ClickHouseVariantMember.value(element: members[Int(discriminator)], bytes: values[state.rowIndex])
            return ClickHouseDynamic(value)
        default: throw typeMismatch(key, expected: "Dynamic")
        }
    }

    private func decodeAggregateState(forKey key: Key) throws -> ClickHouseAggregateState {
        switch try nonNullColumn(forKey: key, expected: "AggregateFunction") {
        case .aggregateFunction(let signature, let states):
            return ClickHouseAggregateState(signature: signature, bytes: states[state.rowIndex])
        default: throw typeMismatch(key, expected: "AggregateFunction")
        }
    }

    private func decodeJSON(forKey key: Key) throws -> ClickHouseJSON {
        switch try nonNullColumn(forKey: key, expected: "JSON") {
        case .string(let values): return ClickHouseJSON(bytes: values[state.rowIndex])
        case .nullableString(let values): return ClickHouseJSON(bytes: try requirePresent(values[state.rowIndex], key: key))
        case .json(let values): return ClickHouseJSON(bytes: values[state.rowIndex])
        default: throw typeMismatch(key, expected: "JSON")
        }
    }

    private func decodeDecimal(forKey key: Key) throws -> ClickHouseDecimal {
        switch try nonNullColumn(forKey: key, expected: "Decimal") {
        case .decimal(let values, _, _): return values[state.rowIndex]
        default: throw typeMismatch(key, expected: "Decimal")
        }
    }

    private static var posixDecimalLocale: Locale { Locale(identifier: "en_US_POSIX") }

    // Foundation.Decimal holds 38 significant digits, so a Decimal256
    // (precision > 38) would round silently — reject it and point back to
    // ClickHouseDecimal for the full value. Within range the lossless
    // decimal string parses exactly; the POSIX locale pins the '.' separator
    // so a comma-decimal host locale cannot corrupt the parse.
    private func decodeFoundationDecimal(forKey key: Key) throws -> Decimal {
        switch try nonNullColumn(forKey: key, expected: "Decimal") {
        case .decimal(let values, let precision, let scale):
            if precision > 38 {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: codingPath + [key],
                    debugDescription: "Decimal(\(precision), \(scale)) exceeds Foundation.Decimal's 38 significant digits; decode column '\(key.stringValue)' as ClickHouseDecimal for the full value."
                ))
            }
            let text = values[state.rowIndex].description
            guard let decimal = Decimal(string: text, locale: Self.posixDecimalLocale) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: codingPath + [key],
                    debugDescription: "Could not parse Decimal value '\(text)' for column '\(key.stringValue)'."
                ))
            }
            return decimal
        default:
            throw typeMismatch(key, expected: "Decimal")
        }
    }

    // A Variant/Dynamic discriminator indexes the member-type list (or is
    // 255 for NULL). Malformed or unexpected wire bytes can carry a value
    // that selects no member; without this guard the member lookup traps
    // and crashes the process. Surface a typed error so a single bad block
    // fails the decode rather than taking down the client.
    private func requireMemberInRange(_ discriminator: UInt8, memberCount: Int, kind: String, stage: String) throws {
        if Int(discriminator) >= memberCount {
            throw ClickHouseError.protocolError(
                stage: stage,
                message: "\(kind) discriminator \(discriminator) at row \(state.rowIndex) selects no member; column declares \(memberCount) member(s), so only 0..<\(memberCount) or 255 (NULL) are valid"
            )
        }
    }

    private func nonNullColumn(forKey key: Key, expected: String) throws -> ClickHouseTypedColumn {
        let resolved = try column(forKey: key)
        guard case .nullable(let mask, let inner) = resolved else { return resolved }
        if mask[state.rowIndex] {
            throw DecodingError.valueNotFound(ClickHouseTypedColumn.self, .init(
                codingPath: codingPath + [key],
                debugDescription: "Column '\(key.stringValue)' is NULL at row \(state.rowIndex) but the destination field is non-Optional."
            ))
        }
        return inner
    }

    private func wrapPresent<T>(forKey key: Key, _ body: () throws -> T) throws -> T? {
        guard case .found(let slot) = state.slot(for: key.stringValue) else { return nil }
        if isNullAt(slot: slot) { return nil }
        // The slot is already resolved; hand it to the inner decode so it
        // reuses it instead of hashing the column name again. The hint is
        // cleared after the body regardless of whether it was consumed, so a
        // body that did not decode a column cannot leak it to the next field.
        state.hintedSlot = slot
        defer { state.hintedSlot = -1 }
        return try body()
    }

    private func requirePresent<T>(_ value: ClickHouseNullable<T>, key: Key) throws -> T {
        switch value {
        case .present(let inner): return inner
        case .absent:
            throw DecodingError.valueNotFound(T.self, .init(
                codingPath: codingPath + [key],
                debugDescription: "Column '\(key.stringValue)' is NULL at row \(state.rowIndex) but the destination field is non-Optional."
            ))
        }
    }

    private func missing(_ key: Key) -> DecodingError {
        .keyNotFound(key, .init(
            codingPath: codingPath,
            debugDescription: "Column '\(key.stringValue)' was not present in the result block."
        ))
    }

    private func typeMismatch(_ key: Key, expected: String) -> DecodingError {
        let actual = (try? column(forKey: key).typeName) ?? "unknown"
        return .typeMismatch(Self.self, .init(
            codingPath: codingPath + [key],
            debugDescription: "Cannot decode column '\(key.stringValue)' as \(expected); column type is \(actual)."
        ))
    }
}
