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

// Vends an unkeyed container over the elements of one Array(Tuple(...)) cell so
// a list of tuples decodes straight into [Struct]. The two tuple sub-columns of
// the cell are rebuilt as named columns carrying one value per array element,
// and each element is decoded as a row of that mini block through the same
// keyed-container path every result row uses.
struct ClickHouseArrayOfTupleDecoder: Decoder {

    let state: ClickHouseColumnarDecoderState
    let total: Int
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] = [:]

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        ClickHouseArrayOfTupleUnkeyedContainer(state: state, total: total, codingPath: codingPath)
    }

    func container<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        throw DecodingError.dataCorrupted(.init(
            codingPath: codingPath,
            debugDescription: "An Array(Tuple) column decodes as an array; request a keyed container only on its element type."
        ))
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        throw DecodingError.dataCorrupted(.init(
            codingPath: codingPath,
            debugDescription: "An Array(Tuple) column decodes as an array, not a single value."
        ))
    }
}

struct ClickHouseArrayOfTupleUnkeyedContainer: UnkeyedDecodingContainer {

    let state: ClickHouseColumnarDecoderState
    let total: Int
    var codingPath: [CodingKey]
    var currentIndex: Int = 0

    var count: Int? { total }
    var isAtEnd: Bool { currentIndex >= total }

    mutating func decodeNil() throws -> Bool { false }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        state.rowIndex = currentIndex
        let value = try T(from: ClickHouseColumnarDecoder(state: state, codingPath: codingPath))
        currentIndex += 1
        return value
    }

    mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        state.rowIndex = currentIndex
        currentIndex += 1
        return try ClickHouseColumnarDecoder(state: state, codingPath: codingPath).container(keyedBy: NestedKey.self)
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw elementMismatch([Any].self)
    }

    mutating func superDecoder() throws -> Decoder {
        state.rowIndex = currentIndex
        currentIndex += 1
        return ClickHouseColumnarDecoder(state: state, codingPath: codingPath)
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool { throw elementMismatch(type) }
    mutating func decode(_ type: String.Type) throws -> String { throw elementMismatch(type) }
    mutating func decode(_ type: Double.Type) throws -> Double { throw elementMismatch(type) }
    mutating func decode(_ type: Float.Type) throws -> Float { throw elementMismatch(type) }
    mutating func decode(_ type: Int.Type) throws -> Int { throw elementMismatch(type) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { throw elementMismatch(type) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { throw elementMismatch(type) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { throw elementMismatch(type) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { throw elementMismatch(type) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { throw elementMismatch(type) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { throw elementMismatch(type) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { throw elementMismatch(type) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { throw elementMismatch(type) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { throw elementMismatch(type) }

    private func elementMismatch(_ expected: Any.Type) -> DecodingError {
        DecodingError.typeMismatch(expected, .init(
            codingPath: codingPath,
            debugDescription: "An Array(Tuple) element decodes into a keyed struct, not \(expected)."
        ))
    }
}
