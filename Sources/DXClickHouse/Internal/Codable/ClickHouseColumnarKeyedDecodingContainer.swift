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
