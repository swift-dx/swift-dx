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

// Maps a Decodable type's coding keys onto the row's named columns. Scalar
// properties read the matching column directly through the typed accessors; a
// property of any other Decodable type is read from a TEXT column holding its
// JSON, which is the convention SwiftDX uses for nested values. Nested keyed and
// unkeyed containers, and super decoders, are not part of a flat row and throw.
struct SQLiteRowKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {

    let row: SQLiteRow
    let codingPath: [CodingKey] = []

    var allKeys: [Key] {
        row.columnNames.compactMap(Key.init(stringValue:))
    }

    func contains(_ key: Key) -> Bool {
        row.columnNames.contains(key.stringValue)
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        guard contains(key) else { return true }
        guard case .null = try value(for: key) else { return false }
        return true
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        try value(for: key).boolean()
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        try value(for: key).text()
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        try value(for: key).double()
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        let raw = try value(for: key).double()
        let narrowed = Float(raw)
        guard !(narrowed.isInfinite && raw.isFinite) else {
            throw SQLiteError.decodingFailed(type: "Float", reason: "double \(raw) is out of Float range")
        }
        return narrowed
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        try boundedInteger(forKey: key)
    }

    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        try boundedInteger(forKey: key)
    }

    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        try boundedInteger(forKey: key)
    }

    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        try boundedInteger(forKey: key)
    }

    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        try value(for: key).integer()
    }

    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        try boundedInteger(forKey: key)
    }

    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        try boundedInteger(forKey: key)
    }

    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        try boundedInteger(forKey: key)
    }

    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        try boundedInteger(forKey: key)
    }

    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        try boundedInteger(forKey: key)
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let text = try value(for: key).text()
        do {
            return try JSONDecoder().decode(T.self, from: Data(text.utf8))
        } catch {
            throw SQLiteError.decodingFailed(type: String(describing: T.self), reason: String(describing: error))
        }
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        throw SQLiteError.decodingFailed(type: key.stringValue, reason: "nested keyed containers are not supported when decoding a row")
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        throw SQLiteError.decodingFailed(type: key.stringValue, reason: "nested unkeyed containers are not supported when decoding a row")
    }

    func superDecoder() throws -> Decoder {
        throw SQLiteError.decodingFailed(type: "super", reason: "super decoders are not supported when decoding a row")
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        throw SQLiteError.decodingFailed(type: key.stringValue, reason: "super decoders are not supported when decoding a row")
    }

    private func value(for key: Key) throws -> SQLiteValue {
        try row.value(named: key.stringValue)
    }

    private func boundedInteger<I: FixedWidthInteger>(forKey key: Key) throws -> I {
        let raw = try value(for: key).integer()
        guard let converted = I(exactly: raw) else {
            throw SQLiteError.decodingFailed(type: String(describing: I.self), reason: "integer \(raw) is out of range")
        }
        return converted
    }
}
