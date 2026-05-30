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

// Per-block Decoder driven by typed-column storage. One instance is
// constructed at the start of each block and reused across every row;
// the row index is bumped between rows so the per-row hot path does not
// reallocate any state. The keyed container resolves each CodingKey to
// a column-position slot exactly once per block, so the second row in
// any block (and every row thereafter) hits typed-array subscripts on
// the decode path with no String hashing.
struct ClickHouseColumnarDecoder: Decoder {

    let state: ClickHouseColumnarDecoderState
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> where Key: CodingKey {
        KeyedDecodingContainer(ClickHouseColumnarKeyedDecodingContainer<Key>(
            state: state, codingPath: codingPath
        ))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.dataCorrupted(.init(
            codingPath: codingPath,
            debugDescription: "Each row must be a keyed container (struct/class). Unkeyed root containers are not supported."
        ))
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        throw DecodingError.dataCorrupted(.init(
            codingPath: codingPath,
            debugDescription: "Each row must be a keyed container (struct/class). Single-value root containers are not supported."
        ))
    }
}

// Shared mutable state for one block of decoding. Owns the typed-column
// array, the row index that advances between rows, and a name→slot
// cache so per-row String hashing only runs once per block per column.
final class ClickHouseColumnarDecoderState {

    let columns: [ClickHouseNamedColumn]
    let columnIndexByName: [String: Int]
    var rowIndex: Int = 0

    init(columns: [ClickHouseNamedColumn]) {
        self.columns = columns
        var index: [String: Int] = [:]
        index.reserveCapacity(columns.count)
        for (offset, column) in columns.enumerated() {
            index[column.name] = offset
        }
        self.columnIndexByName = index
    }

    func slot(for key: String) -> Int? {
        columnIndexByName[key]
    }
}
