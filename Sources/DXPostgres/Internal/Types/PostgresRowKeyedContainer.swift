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

// Reads a struct's properties from the result row's columns by name. Each typed
// `decode` delegates to the matching column decoder; integer properties are
// decoded width-tolerantly (a column of any integer width) and then narrowed to
// the requested Swift width, failing if the value does not fit. Optional
// properties work through the protocol's default `decodeIfPresent`, which uses
// `contains` and `decodeNil`.
struct PostgresRowKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {

    let row: PostgresRow
    let codingPath: [CodingKey] = []

    var allKeys: [Key] {
        row.columns.compactMap { Key(stringValue: $0.name) }
    }

    func contains(_ key: Key) -> Bool {
        row.columns.contains { $0.name == key.stringValue }
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        switch try row.cell(named: key.stringValue) {
        case .sqlNull: return true
        case .bytes: return false
        }
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        try row.decode(Bool.self, named: key.stringValue)
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        try row.decode(String.self, named: key.stringValue)
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        try row.decode(Double.self, named: key.stringValue)
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        try row.decode(Float.self, named: key.stringValue)
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try narrowing(key) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try narrowing(key) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try narrowing(key) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try narrowing(key) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try narrowing(key) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try narrowing(key) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try narrowing(key) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try narrowing(key) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try narrowing(key) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try narrowing(key) }

    func decode<Value: Decodable>(_ type: Value.Type, forKey key: Key) throws -> Value {
        try PostgresRowDecoder.decodeScalar(type, from: row, column: row.index(ofColumn: key.stringValue))
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        throw PostgresError.typeDecodingFailed(type: "\(NestedKey.self)", reason: "nested keyed containers are unsupported; map a JSON column to a Decodable value")
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        throw PostgresError.typeDecodingFailed(type: "Array", reason: "nested unkeyed containers are unsupported")
    }

    func superDecoder() throws -> Decoder {
        PostgresRowDecoder(row: row)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        PostgresRowDecoder(row: row)
    }

    private func narrowing<Value: FixedWidthInteger>(_ key: Key) throws -> Value {
        let wide = try row.decode(Int.self, named: key.stringValue)
        guard let value = Value(exactly: wide) else {
            throw PostgresError.typeDecodingFailed(type: "\(Value.self)", reason: "value \(wide) does not fit \(Value.self)")
        }
        return value
    }
}
