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
        switch try column(forKey: key) {
        case .string(let values): return values[state.rowIndex]
        case .nullableString(let values): return try requirePresent(values[state.rowIndex], key: key)
        default: throw typeMismatch(key, expected: "String")
        }
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
        throw DecodingError.typeMismatch(T.self, .init(
            codingPath: codingPath + [key],
            debugDescription: "Unsupported Swift decode target \(String(describing: T.self)) for column '\(key.stringValue)'."
        ))
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
        switch try column(forKey: key) {
        case .dateTime(let values): return values[state.rowIndex]
        case .nullableDateTime(let values): return try requirePresent(values[state.rowIndex], key: key)
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
            return ClickHouseTuple(
                elements: ClickHouseTupleColumnBuilder.elementTypes(of: columns),
                values: ClickHouseTupleColumnBuilder.rawElementBytes(columns: columns, rowIndex: state.rowIndex)
            )
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
        case .arrayOfTuple(let firstValues, let secondValues, let firstElement, let secondElement):
            return ClickHouseArrayOfTuple(
                firstElement: firstElement,
                secondElement: secondElement,
                firstValues: firstValues[state.rowIndex],
                secondValues: secondValues[state.rowIndex]
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
        case .string(let values): return ClickHouseJSON(bytes: Array(values[state.rowIndex].utf8))
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
