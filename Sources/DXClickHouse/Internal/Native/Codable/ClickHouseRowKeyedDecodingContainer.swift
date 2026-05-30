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

// KeyedDecodingContainer that resolves Codable's per-field
// `decode(_, forKey:)` calls into the typed column arrays held by
// `ClickHouseRowDecoderStorage`. Type mismatches surface as
// `DecodingError.typeMismatch`; missing columns as
// `DecodingError.keyNotFound`.
struct ClickHouseRowKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {

    let storage: ClickHouseRowDecoderStorage
    let rowIndex: Int
    let keyDecodingStrategy: ClickHouseKeyDecodingStrategy
    var codingPath: [CodingKey]

    var allKeys: [Key] {
        storage.columnOrder.compactMap(Key.init(stringValue:))
    }

    func contains(_ key: Key) -> Bool {
        storage.columnsByName[columnName(for: key)] != nil
    }

    private func columnName(for key: Key) -> String {
        keyDecodingStrategy.columnName(forSwiftKey: key.stringValue)
    }

    private func column(for key: Key) throws -> ClickHouseColumnEntry.Values {
        let lookupName = columnName(for: key)
        guard let values = storage.columnsByName[lookupName] else {
            throw DecodingError.keyNotFound(
                key,
                .init(codingPath: codingPath, debugDescription: "No column named '\(lookupName)' (Swift key '\(key.stringValue)') in the SELECT result")
            )
        }
        return values
    }

    private func typeMismatch<T>(
        _ key: Key, expected: T.Type, actual: ClickHouseColumnEntry.Values
    ) -> DecodingError {
        DecodingError.typeMismatch(
            T.self,
            .init(codingPath: codingPath + [key],
                  debugDescription: "Column '\(key.stringValue)' is \(actual) but the target type wanted \(T.self)")
        )
    }

    private func unsupportedShape(_ key: Key, _ values: ClickHouseColumnEntry.Values) -> ClickHouseError {
        ClickHouseError.rowDecoderUnsupportedColumnValueShape(
            columnName: key.stringValue,
            valueDescription: "\(values)"
        )
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        // For nullable columns, decodeNil returns true if the
        // value at this row is absent. For non-nullable columns,
        // always returns false (the value is always present).
        // Codable's default decodeIfPresent calls decodeNil first;
        // if true, returns nil; otherwise calls decode(_, forKey:)
        // which then reads the unwrapped value from the nullable
        // column.
        guard let values = storage.columnsByName[columnName(for: key)] else {
            // Missing column → treat as "not present" so
            // decodeIfPresent returns nil (matches Codable's
            // standard behavior for missing optional fields).
            return true
        }
        switch values {
        case .nullableString(let v): return isAbsent(v[rowIndex])
        case .nullableBool(let v): return isAbsent(v[rowIndex])
        case .nullableInt8(let v): return isAbsent(v[rowIndex])
        case .nullableInt16(let v): return isAbsent(v[rowIndex])
        case .nullableInt32(let v): return isAbsent(v[rowIndex])
        case .nullableInt64(let v): return isAbsent(v[rowIndex])
        case .nullableUInt8(let v): return isAbsent(v[rowIndex])
        case .nullableUInt16(let v): return isAbsent(v[rowIndex])
        case .nullableUInt32(let v): return isAbsent(v[rowIndex])
        case .nullableUInt64(let v): return isAbsent(v[rowIndex])
        case .nullableFloat32(let v): return isAbsent(v[rowIndex])
        case .nullableFloat64(let v): return isAbsent(v[rowIndex])
        case .nullableDateTime(let v): return isAbsent(v[rowIndex])
        case .nullableUUID(let v): return isAbsent(v[rowIndex])
        default:
            // Non-nullable column → never nil.
            return false
        }
    }

    private func isAbsent<T>(_ element: ClickHouseNullable<T>) -> Bool {
        if case .absent = element { return true }
        return false
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        let values = try column(for: key)
        switch values {
        case .bool(let arr): return arr[rowIndex]
        case .nullableBool(let arr):
            return try unwrapNullable(arr[rowIndex], type: type, key: key, label: "Bool")
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        let values = try column(for: key)
        switch values {
        case .string(let arr): return arr[rowIndex]
        case .lowCardinalityString(let arr): return arr[rowIndex]
        case .lowCardinalityStringIndexed(let view): return view[rowIndex]
        case .nullableString(let arr):
            return try unwrapNullable(arr[rowIndex], type: type, key: key, label: "String")
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        let values = try column(for: key)
        switch values {
        case .float64(let arr): return arr[rowIndex]
        case .nullableFloat64(let arr):
            return try unwrapNullable(arr[rowIndex], type: type, key: key, label: "Double")
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        let values = try column(for: key)
        switch values {
        case .float32(let arr): return arr[rowIndex]
        case .nullableFloat32(let arr):
            return try unwrapNullable(arr[rowIndex], type: type, key: key, label: "Float")
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    private func unwrapNullable<T>(_ element: ClickHouseNullable<T>, type: T.Type, key: Key, label: String) throws -> T {
        switch element {
        case .present(let value): return value
        case .absent:
            throw DecodingError.valueNotFound(T.self, .init(
                codingPath: codingPath + [key],
                debugDescription: "Nullable column '\(key.stringValue)' returned nil at row \(rowIndex) but caller asked for non-Optional \(label)"
            ))
        }
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        throw ClickHouseError.rowEncoderUnsupportedType(
            swiftTypeDescription: "Int",
            columnName: key.stringValue,
            message: "Swift `Int` is platform-dependent. Decode into a fixed-width type (Int32, Int64) so column type is unambiguous."
        )
    }

    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        let values = try column(for: key)
        switch values {
        case .int8(let arr): return arr[rowIndex]
        case .nullableInt8(let arr): return try unwrapNullable(arr[rowIndex], type: type, key: key, label: "Int8")
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        let values = try column(for: key)
        switch values {
        case .int16(let arr): return arr[rowIndex]
        case .nullableInt16(let arr): return try unwrapNullable(arr[rowIndex], type: type, key: key, label: "Int16")
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        let values = try column(for: key)
        switch values {
        case .int32(let arr): return arr[rowIndex]
        case .nullableInt32(let arr): return try unwrapNullable(arr[rowIndex], type: type, key: key, label: "Int32")
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        let values = try column(for: key)
        switch values {
        case .int64(let arr): return arr[rowIndex]
        case .nullableInt64(let arr): return try unwrapNullable(arr[rowIndex], type: type, key: key, label: "Int64")
        case .dateTime64Nanoseconds(let arr, _): return arr[rowIndex].rawValue
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        throw ClickHouseError.rowEncoderUnsupportedType(
            swiftTypeDescription: "UInt",
            columnName: key.stringValue,
            message: "Swift `UInt` is platform-dependent. Decode into a fixed-width type (UInt32, UInt64)."
        )
    }

    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        let values = try column(for: key)
        switch values {
        case .uint8(let arr): return arr[rowIndex]
        case .nullableUInt8(let arr): return try unwrapNullable(arr[rowIndex], type: type, key: key, label: "UInt8")
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        let values = try column(for: key)
        switch values {
        case .uint16(let arr): return arr[rowIndex]
        case .nullableUInt16(let arr): return try unwrapNullable(arr[rowIndex], type: type, key: key, label: "UInt16")
        case .date(let arr): return UInt16(arr[rowIndex].timeIntervalSince1970 / 86_400)
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        let values = try column(for: key)
        switch values {
        case .uint32(let arr): return arr[rowIndex]
        case .nullableUInt32(let arr): return try unwrapNullable(arr[rowIndex], type: type, key: key, label: "UInt32")
        case .dateTime(let arr): return UInt32(arr[rowIndex].timeIntervalSince1970)
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        let values = try column(for: key)
        switch values {
        case .uint64(let arr): return arr[rowIndex]
        case .nullableUInt64(let arr): return try unwrapNullable(arr[rowIndex], type: type, key: key, label: "UInt64")
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        if let result = try decodeScalarSpecialType(type, forKey: key) { return result }
        if let result = try decodeArraySpecialType(type, forKey: key) { return result }
        throw ClickHouseError.rowEncoderUnsupportedType(
            swiftTypeDescription: String(describing: type),
            columnName: key.stringValue,
            message: "ClickHouseRowDecoder supports primitive Codable types, Date, UUID, and [String: String]. Other dictionaries, row-level arrays, and nested structs are not supported."
        )
    }

    private func decodeScalarSpecialType<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        if type == Date.self { return try decodeDate(type, forKey: key) }
        return try decodeUUIDOrStringMap(type, forKey: key)
    }

    private func decodeUUIDOrStringMap<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        if type == UUID.self { return try decodeUUID(type, forKey: key) }
        if type == [String: String].self { return try decodeStringStringMap(type, forKey: key) }
        return nil
    }

    private func decodeArraySpecialType<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        if type == [UInt64].self { return try decodeUInt64Array(type, forKey: key) }
        if type == [Double].self { return try decodeDoubleArray(type, forKey: key) }
        return nil
    }

    private func decodeDate<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let values = try column(for: key)
        switch values {
        case .dateTime(let arr): return try castOrThrow(arr[rowIndex], type: type, key: key, values: values)
        case .nullableDateTime(let arr): return try castNullable(arr[rowIndex], type: type, key: key, values: values, label: "Date")
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    private func decodeUUID<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let values = try column(for: key)
        switch values {
        case .uuid(let arr): return try castOrThrow(arr[rowIndex], type: type, key: key, values: values)
        case .nullableUUID(let arr): return try castNullable(arr[rowIndex], type: type, key: key, values: values, label: "UUID")
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    private func decodeStringStringMap<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let values = try column(for: key)
        switch values {
        case .mapStringString(let arr): return try castOrThrow(arr[rowIndex], type: type, key: key, values: values)
        case .mapStringStringIndexed(let storage):
            return try castOrThrow(storage.row(at: rowIndex), type: type, key: key, values: values)
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    private func decodeUInt64Array<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let values = try column(for: key)
        if case .arrayOfUInt64(let arr) = values, let result = arr[rowIndex] as? T {
            return result
        }
        throw typeMismatch(key, expected: type, actual: values)
    }

    private func decodeDoubleArray<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let values = try column(for: key)
        if case .arrayOfFloat64(let arr) = values, let result = arr[rowIndex] as? T {
            return result
        }
        throw typeMismatch(key, expected: type, actual: values)
    }

    private func castOrThrow<Source, T: Decodable>(_ source: Source, type: T.Type, key: Key, values: ClickHouseColumnEntry.Values) throws -> T {
        guard let result = source as? T else {
            throw typeMismatch(key, expected: type, actual: values)
        }
        return result
    }

    private func castNullable<Source, T: Decodable>(_ source: ClickHouseNullable<Source>, type: T.Type, key: Key, values: ClickHouseColumnEntry.Values, label: String) throws -> T {
        switch source {
        case .present(let unwrapped):
            return try castOrThrow(unwrapped, type: type, key: key, values: values)
        case .absent:
            throw DecodingError.valueNotFound(T.self, .init(
                codingPath: codingPath + [key],
                debugDescription: "Nullable column '\(key.stringValue)' returned nil at row \(rowIndex) but caller asked for non-Optional \(label)"
            ))
        }
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        throw DecodingError.dataCorrupted(.init(
            codingPath: codingPath + [key],
            debugDescription: "Nested keyed containers are not supported. SELECT rows must decode into a flat struct of supported primitives."
        ))
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        throw DecodingError.dataCorrupted(.init(
            codingPath: codingPath + [key],
            debugDescription: "Nested unkeyed containers are not supported. SELECT rows must decode into a flat struct of supported primitives."
        ))
    }

    func superDecoder() throws -> Decoder {
        throw DecodingError.dataCorrupted(.init(
            codingPath: codingPath,
            debugDescription: "superDecoder is not supported by ClickHouseRowDecoder."
        ))
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        throw DecodingError.dataCorrupted(.init(
            codingPath: codingPath + [key],
            debugDescription: "superDecoder(forKey:) is not supported by ClickHouseRowDecoder."
        ))
    }

}
