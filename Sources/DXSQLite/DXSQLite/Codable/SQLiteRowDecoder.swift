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

// Decodes one result row into a Decodable value. A row is a flat set of named
// columns, so only a keyed container is meaningful; unkeyed and single-value
// containers throw rather than inventing a shape the row does not have.
struct SQLiteRowDecoder: Decoder {

    let row: SQLiteRow
    let codingPath: [CodingKey] = []
    let userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(SQLiteRowKeyedContainer<Key>(row: row))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw SQLiteError.decodingFailed(type: "row", reason: "a row decodes into a keyed type, not an unkeyed container")
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        throw SQLiteError.decodingFailed(type: "row", reason: "a row decodes into a keyed type, not a single value")
    }
}
