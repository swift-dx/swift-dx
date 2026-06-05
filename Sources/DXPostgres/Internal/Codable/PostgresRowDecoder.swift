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

// Decodes one row into a Decodable value. Columns arrive in text format, keyed by
// name; a property reads the cell whose column name matches its coding key. Null
// is surfaced through decodeNil so optional and non-optional properties both work.
struct PostgresRowDecoder: Decoder {

    let row: [PostgresCell]
    let columnIndex: [String: Int]
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(PostgresRowKeyedContainer<Key>(row: row, columnIndex: columnIndex))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "a PostgreSQL row decodes into a keyed type, not an unkeyed container"))
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "a PostgreSQL row decodes into a keyed type, not a single value"))
    }
}

struct PostgresRowKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {

    let row: [PostgresCell]
    let columnIndex: [String: Int]
    var codingPath: [CodingKey] = []
    var allKeys: [Key] { columnIndex.keys.compactMap { Key(stringValue: $0) } }

    func contains(_ key: Key) -> Bool { columnIndex[key.stringValue] != nil }

    func decodeNil(forKey key: Key) throws -> Bool {
        if case .sqlNull = try cell(key) { return true }
        return false
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try boolean(key) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try text(key) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try floating(key) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { Float(try floating(key)) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try integer(key) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try integer(key) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try integer(key) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try integer(key) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try integer(key) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try integer(key) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try integer(key) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try integer(key) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try integer(key) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try integer(key) }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        throw DecodingError.typeMismatch(type, .init(codingPath: codingPath + [key], debugDescription: "column \(key.stringValue) decodes only to a built-in scalar; nested decoding is not supported"))
    }

    func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        throw DecodingError.dataCorrupted(.init(codingPath: codingPath + [key], debugDescription: "nested containers are not supported"))
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        throw DecodingError.dataCorrupted(.init(codingPath: codingPath + [key], debugDescription: "nested containers are not supported"))
    }

    func superDecoder() throws -> any Decoder {
        PostgresRowDecoder(row: row, columnIndex: columnIndex)
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        PostgresRowDecoder(row: row, columnIndex: columnIndex)
    }

    private func cell(_ key: Key) throws -> PostgresCell {
        guard let index = columnIndex[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "no column named \(key.stringValue) in the row"))
        }
        return row[index]
    }

    private func text(_ key: Key) throws -> String {
        switch try cell(key) {
        case .sqlNull: throw DecodingError.valueNotFound(String.self, .init(codingPath: codingPath + [key], debugDescription: "column \(key.stringValue) is NULL"))
        case .bytes(let bytes):
            guard let string = String(validating: bytes, as: UTF8.self) else {
                throw DecodingError.dataCorrupted(.init(codingPath: codingPath + [key], debugDescription: "column \(key.stringValue) is not valid UTF-8"))
            }
            return string
        }
    }

    private func integer<Value: FixedWidthInteger>(_ key: Key) throws -> Value {
        guard let value = Value(try text(key)) else {
            throw DecodingError.typeMismatch(Value.self, .init(codingPath: codingPath + [key], debugDescription: "column \(key.stringValue) is not a \(Value.self)"))
        }
        return value
    }

    private func boolean(_ key: Key) throws -> Bool {
        switch try text(key) {
        case "t": return true
        case "f": return false
        case let other: throw DecodingError.typeMismatch(Bool.self, .init(codingPath: codingPath + [key], debugDescription: "column \(key.stringValue) is not a boolean: \(other)"))
        }
    }

    private func floating(_ key: Key) throws -> Double {
        guard let value = Double(try text(key)) else {
            throw DecodingError.typeMismatch(Double.self, .init(codingPath: codingPath + [key], debugDescription: "column \(key.stringValue) is not a number"))
        }
        return value
    }
}
