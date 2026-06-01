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

// A Swift `Decoder` that maps one result row onto a `Decodable` value. A keyed
// value (a struct) reads each property from the column of the same name; a single
// value reads the first column. The bridge from Codable's generic decode calls to
// the column-level `PostgresDecodable` decoders is `decodeScalar`, which routes
// the well-known leaf types (`UUID`, `Date`, `Decimal`, byte arrays) to their
// binary/text decoders and treats any other nested `Decodable` as a JSON column.
struct PostgresRowDecoder: Decoder {

    let row: PostgresRow
    let codingPath: [CodingKey] = []
    let userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(PostgresRowKeyedContainer<Key>(row: row))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw PostgresError.typeDecodingFailed(type: "Array", reason: "a result row decodes to a struct or a single column, not an unkeyed array")
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        PostgresRowSingleValueContainer(row: row)
    }

    // Routes a generic Decodable column value to a concrete column decoder. The
    // leaf types map to their PostgresDecodable conformance; anything else is read
    // as a JSON column. The `as!` casts are safe: the value was decoded as exactly
    // the matched type.
    static func decodeScalar<Value: Decodable>(_ type: Value.Type, from row: PostgresRow, column index: Int) throws(PostgresError) -> Value {
        if type == UUID.self { return try row.decode(UUID.self, at: index) as! Value }
        if type == Date.self { return try row.decode(Date.self, at: index) as! Value }
        if type == Decimal.self { return try row.decode(Decimal.self, at: index) as! Value }
        if type == [UInt8].self { return try row.decode([UInt8].self, at: index) as! Value }
        if type == Data.self { return try Data(row.decode([UInt8].self, at: index)) as! Value }
        return try decodeJSONColumn(type, from: row, column: index)
    }

    private static func decodeJSONColumn<Value: Decodable>(_ type: Value.Type, from row: PostgresRow, column index: Int) throws(PostgresError) -> Value {
        switch try row.cell(at: index) {
        case .sqlNull: throw PostgresError.columnIsNull(column: "index \(index)")
        case .bytes: return try row.decodeJSON(type, at: index)
        }
    }
}
