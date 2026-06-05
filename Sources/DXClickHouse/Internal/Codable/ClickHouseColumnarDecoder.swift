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
// the shared `state`'s row index is bumped between rows so no per-row
// decoder or column storage is reallocated. Codable still asks this
// decoder for a fresh keyed container inside each row's `init(from:)`,
// and that container resolves every field by hashing the CodingKey's
// string against the block's name->index map (`state.slot(for:)`), so a
// field access is an O(1) hashed lookup followed by a typed-array
// subscript at the current row index.
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
// array, the row index that advances between rows, and the
// `columnIndexByName` map built once per block. Field access hashes the
// column name into that map (`slot(for:)`) on every lookup; the map
// itself is computed a single time when the block is parsed, not per row.
final class ClickHouseColumnarDecoderState {

    let columns: [ClickHouseNamedColumn]
    let columnIndexByName: [String: Int]
    var rowIndex: Int = 0

    // One-shot column-slot hint, -1 when unset. decodeIfPresent resolves a
    // field's slot once to check presence, then immediately decodes the same
    // field; the hint lets that inner decode reuse the resolved slot instead
    // of hashing the column name a second time. Live only across one
    // decode-if-present body (set then deferred-cleared), so it cannot leak
    // a stale slot to the next field. Decoding is single-threaded per row, so
    // no synchronization is needed.
    var hintedSlot: Int = -1

    init(columns: [ClickHouseNamedColumn]) {
        self.columns = columns
        var index: [String: Int] = [:]
        index.reserveCapacity(columns.count)
        for (offset, column) in columns.enumerated() {
            index[column.name] = offset
        }
        self.columnIndexByName = index
    }

    enum SlotLookup {
        case found(Int)
        case missing
    }

    func slot(for key: String) -> SlotLookup {
        if let index = columnIndexByName[key] {
            return .found(index)
        }
        return .missing
    }
}
