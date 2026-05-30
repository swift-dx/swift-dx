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

// Hot-path KeyedDecodingContainer for the columnar fast SELECT path.
// Every `decode(_:forKey:)` call resolves the key through the
// shared per-block slot cache (one String hash + one strategy call
// per CodingKey for the whole block), then indexes the typed-column
// array at `state.rowIndex`.
//
// Two cost reductions vs. `ClickHouseRowKeyedDecodingContainer`:
//
// 1. CodingKey → column-position resolution happens once per block,
//    not once per row. After the first row in a block, the cache is
//    fully populated and lookups collapse to one `Dictionary.find`
//    on a per-block local dictionary keyed by the CodingKey's
//    String.
//
// 2. Per-field column unwrap reads from a position-indexed
//    `[Values]` array on the state, replacing the previous
//    `[String: Values].find` dictionary probe.
//
// Type-specific overloads for `Date`, `UUID`, and `[String: String]`
// bypass the generic `decode<T: Decodable>(_:forKey:)` path so the
// `as? T` runtime cast on the cold side is also skipped.
final class ClickHouseColumnarKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {

    let state: ClickHouseColumnarDecoderState
    var codingPath: [CodingKey]

    init(state: ClickHouseColumnarDecoderState, codingPath: [CodingKey]) {
        self.state = state
        self.codingPath = codingPath
    }

    var allKeys: [Key] {
        state.columns.compactMap { Key(stringValue: $0.name) }
    }

    func contains(_ key: Key) -> Bool {
        if case .present = state.slot(for: key.stringValue) { return true }
        return false
    }

    @inline(__always)
    private func valuesOrThrow(_ key: Key) throws -> ClickHouseColumnEntry.Values {
        switch state.slot(for: key.stringValue) {
        case .present(let slot):
            return state.columnsValues[slot]
        case .absent:
            let lookupName = state.keyDecodingStrategy.columnName(forSwiftKey: key.stringValue)
            throw DecodingError.keyNotFound(
                key,
                .init(codingPath: codingPath, debugDescription: "No column named '\(lookupName)' (Swift key '\(key.stringValue)') in the SELECT result")
            )
        }
    }

    private func typeMismatch<T>(_ key: Key, expected: T.Type, actual: ClickHouseColumnEntry.Values) -> DecodingError {
        DecodingError.typeMismatch(
            T.self,
            .init(codingPath: codingPath + [key],
                  debugDescription: "Column '\(key.stringValue)' is \(actual) but the target type wanted \(T.self)")
        )
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        guard case .present(let slot) = state.slot(for: key.stringValue) else {
            return true
        }
        return Self.isNull(state.columnsValues[slot], rowIndex: state.rowIndex)
    }

    private static func isNull(_ values: ClickHouseColumnEntry.Values, rowIndex: Int) -> Bool {
        switch values {
        case .nullableString(let arr): return isAbsent(arr[rowIndex])
        case .nullableBool(let arr): return isAbsent(arr[rowIndex])
        case .nullableInt8(let arr): return isAbsent(arr[rowIndex])
        case .nullableInt16(let arr): return isAbsent(arr[rowIndex])
        case .nullableInt32(let arr): return isAbsent(arr[rowIndex])
        case .nullableInt64(let arr): return isAbsent(arr[rowIndex])
        case .nullableUInt8(let arr): return isAbsent(arr[rowIndex])
        case .nullableUInt16(let arr): return isAbsent(arr[rowIndex])
        case .nullableUInt32(let arr): return isAbsent(arr[rowIndex])
        case .nullableUInt64(let arr): return isAbsent(arr[rowIndex])
        case .nullableFloat32(let arr): return isAbsent(arr[rowIndex])
        case .nullableFloat64(let arr): return isAbsent(arr[rowIndex])
        case .nullableDateTime(let arr): return isAbsent(arr[rowIndex])
        case .nullableUUID(let arr): return isAbsent(arr[rowIndex])
        default: return false
        }
    }

    private static func isAbsent<T>(_ element: ClickHouseNullable<T>) -> Bool {
        if case .absent = element { return true }
        return false
    }

    private func unwrapNullable<T>(_ element: ClickHouseNullable<T>, type: T.Type, key: Key, label: String) throws -> T {
        switch element {
        case .present(let value): return value
        case .absent:
            throw DecodingError.valueNotFound(T.self, .init(
                codingPath: codingPath + [key],
                debugDescription: "Nullable column '\(key.stringValue)' returned nil at row \(state.rowIndex) but caller asked for non-Optional \(label)"
            ))
        }
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        let values = try valuesOrThrow(key)
        switch values {
        case .bool(let arr): return arr[state.rowIndex]
        case .nullableBool(let arr): return try unwrapNullable(arr[state.rowIndex], type: type, key: key, label: "Bool")
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        let values = try valuesOrThrow(key)
        switch values {
        case .string(let arr): return arr[state.rowIndex]
        case .lowCardinalityString(let arr): return arr[state.rowIndex]
        case .lowCardinalityStringIndexed(let view):
            return view.dictionary[Int(view.indices[state.rowIndex])]
        case .nullableString(let arr): return try unwrapNullable(arr[state.rowIndex], type: type, key: key, label: "String")
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        let values = try valuesOrThrow(key)
        switch values {
        case .float64(let arr): return arr[state.rowIndex]
        case .nullableFloat64(let arr): return try unwrapNullable(arr[state.rowIndex], type: type, key: key, label: "Double")
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        let values = try valuesOrThrow(key)
        switch values {
        case .float32(let arr): return arr[state.rowIndex]
        case .nullableFloat32(let arr): return try unwrapNullable(arr[state.rowIndex], type: type, key: key, label: "Float")
        default: throw typeMismatch(key, expected: type, actual: values)
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
        let values = try valuesOrThrow(key)
        switch values {
        case .int8(let arr): return arr[state.rowIndex]
        case .nullableInt8(let arr): return try unwrapNullable(arr[state.rowIndex], type: type, key: key, label: "Int8")
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        let values = try valuesOrThrow(key)
        switch values {
        case .int16(let arr): return arr[state.rowIndex]
        case .nullableInt16(let arr): return try unwrapNullable(arr[state.rowIndex], type: type, key: key, label: "Int16")
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        let values = try valuesOrThrow(key)
        switch values {
        case .int32(let arr): return arr[state.rowIndex]
        case .nullableInt32(let arr): return try unwrapNullable(arr[state.rowIndex], type: type, key: key, label: "Int32")
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        let values = try valuesOrThrow(key)
        switch values {
        case .int64(let arr): return arr[state.rowIndex]
        case .nullableInt64(let arr): return try unwrapNullable(arr[state.rowIndex], type: type, key: key, label: "Int64")
        case .dateTime64Nanoseconds(let arr, _): return arr[state.rowIndex].rawValue
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
        let values = try valuesOrThrow(key)
        switch values {
        case .uint8(let arr): return arr[state.rowIndex]
        case .nullableUInt8(let arr): return try unwrapNullable(arr[state.rowIndex], type: type, key: key, label: "UInt8")
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        let values = try valuesOrThrow(key)
        switch values {
        case .uint16(let arr): return arr[state.rowIndex]
        case .nullableUInt16(let arr): return try unwrapNullable(arr[state.rowIndex], type: type, key: key, label: "UInt16")
        case .date(let arr): return UInt16(arr[state.rowIndex].timeIntervalSince1970 / 86_400)
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        let values = try valuesOrThrow(key)
        switch values {
        case .uint32(let arr): return arr[state.rowIndex]
        case .nullableUInt32(let arr): return try unwrapNullable(arr[state.rowIndex], type: type, key: key, label: "UInt32")
        case .dateTime(let arr): return UInt32(arr[state.rowIndex].timeIntervalSince1970)
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        let values = try valuesOrThrow(key)
        switch values {
        case .uint64(let arr): return arr[state.rowIndex]
        case .nullableUInt64(let arr): return try unwrapNullable(arr[state.rowIndex], type: type, key: key, label: "UInt64")
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    // Codable's auto-synth for `let ts: Date` calls
    // `container.decode(Date.self, forKey:)`, which routes through
    // `KeyedDecodingContainer<Key>.decode<T: Decodable>(_:forKey:)`
    // — the protocol's typed overloads only exist for the primitive
    // scalars listed on the protocol. To bypass the generic
    // `T(from:)` re-entry plus its `as? T` cast, the generic
    // `decode<T>` below dispatches on metatype identity to the
    // type-specific reader.
    private func decodeDate<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let values = try valuesOrThrow(key)
        switch values {
        case .dateTime(let arr): return try castOrThrow(arr[state.rowIndex], type: type, key: key, values: values)
        case .date(let arr): return try castOrThrow(arr[state.rowIndex], type: type, key: key, values: values)
        case .date32(let arr): return try castOrThrow(arr[state.rowIndex], type: type, key: key, values: values)
        case .nullableDateTime(let arr): return try castNullable(arr[state.rowIndex], type: type, key: key, values: values, label: "Date")
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    private func decodeUUID<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let values = try valuesOrThrow(key)
        switch values {
        case .uuid(let arr): return try castOrThrow(arr[state.rowIndex], type: type, key: key, values: values)
        case .nullableUUID(let arr): return try castNullable(arr[state.rowIndex], type: type, key: key, values: values, label: "UUID")
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    private func castNullable<Source, T: Decodable>(_ source: ClickHouseNullable<Source>, type: T.Type, key: Key, values: ClickHouseColumnEntry.Values, label: String) throws -> T {
        switch source {
        case .present(let unwrapped):
            return try castOrThrow(unwrapped, type: type, key: key, values: values)
        case .absent:
            throw DecodingError.valueNotFound(T.self, .init(
                codingPath: codingPath + [key],
                debugDescription: "Nullable column '\(key.stringValue)' returned nil at row \(state.rowIndex) but caller asked for non-Optional \(label)"
            ))
        }
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        switch ClickHouseColumnarDispatch.classify(type) {
        case .date: return try decodeDate(type, forKey: key)
        case .uuid: return try decodeUUID(type, forKey: key)
        case .stringStringMap: return try decodeStringStringMap(type, forKey: key)
        case .uint64Array: return try decodeUInt64Array(type, forKey: key)
        case .doubleArray: return try decodeDoubleArray(type, forKey: key)
        case .unsupported: throw unsupportedTypeError(type, key: key)
        }
    }

    private func unsupportedTypeError<T: Decodable>(_ type: T.Type, key: Key) -> ClickHouseError {
        ClickHouseError.rowEncoderUnsupportedType(
            swiftTypeDescription: String(describing: type),
            columnName: key.stringValue,
            message: "ClickHouseColumnarDecoder supports primitive Codable types, Date, UUID, and [String: String]. Other dictionaries, row-level arrays, and nested structs are not supported."
        )
    }

    private func decodeStringStringMap<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let values = try valuesOrThrow(key)
        switch values {
        case .mapStringString(let arr):
            return try castOrThrow(arr[state.rowIndex], type: type, key: key, values: values)
        case .mapStringStringIndexed(let storage):
            return try castOrThrow(storage.row(at: state.rowIndex), type: type, key: key, values: values)
        default: throw typeMismatch(key, expected: type, actual: values)
        }
    }

    private func decodeUInt64Array<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let values = try valuesOrThrow(key)
        if case .arrayOfUInt64(let arr) = values, let result = arr[state.rowIndex] as? T {
            return result
        }
        throw typeMismatch(key, expected: type, actual: values)
    }

    private func decodeDoubleArray<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let values = try valuesOrThrow(key)
        if case .arrayOfFloat64(let arr) = values, let result = arr[state.rowIndex] as? T {
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
            debugDescription: "superDecoder is not supported by ClickHouseColumnarDecoder."
        ))
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        throw DecodingError.dataCorrupted(.init(
            codingPath: codingPath + [key],
            debugDescription: "superDecoder(forKey:) is not supported by ClickHouseColumnarDecoder."
        ))
    }

}
