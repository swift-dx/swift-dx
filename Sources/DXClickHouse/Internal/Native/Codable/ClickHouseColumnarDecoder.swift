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

// Per-block `Decoder` driven by typed-column storage. One instance
// is constructed at the start of each `ClickHouseSelectBlock` and
// reused across every row in the block; the per-row hot path
// mutates `state.rowIndex` between rows without reallocating the
// decoder or the keyed container behind it.
//
// The container resolves each `CodingKey` to a column-position slot
// exactly once per block via `ClickHouseColumnarDecoderState.slot`,
// so the second row in any block (and every row thereafter) hits
// only typed-array subscripts on the decode path. Compared with the
// dictionary-keyed `ClickHouseRowKeyedDecodingContainer`, this
// removes one String hash, one String comparison, and one
// `KeyDecodingStrategy.columnName` call per field per row.
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
            debugDescription: "ClickHouseColumnarDecoder requires each row to be a keyed container — unkeyed root containers are not supported."
        ))
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        throw DecodingError.dataCorrupted(.init(
            codingPath: codingPath,
            debugDescription: "ClickHouseColumnarDecoder requires each row to be a keyed container — single-value root containers are not supported."
        ))
    }

}
