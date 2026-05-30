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

// Internal Encoder implementation. The public surface is
// `ClickHouseRowEncoder`; this is the per-row instance that the
// Codable runtime drives via `T.encode(to:)`.
struct ClickHouseRowEncoderImpl: Encoder {

    let storage: ClickHouseRowColumnStorage
    let keyEncodingStrategy: ClickHouseKeyEncodingStrategy
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> where Key: CodingKey {
        KeyedEncodingContainer(ClickHouseRowKeyedContainer<Key>(
            storage: storage,
            keyEncodingStrategy: keyEncodingStrategy,
            codingPath: codingPath
        ))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        ClickHouseRowRejectingContainer(
            codingPath: codingPath,
            message: "ClickHouseRowEncoder requires each row to be a keyed container (struct/class) — unkeyed containers (arrays at the row level) are not supported."
        )
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        ClickHouseRowRejectingContainer(
            codingPath: codingPath,
            message: "ClickHouseRowEncoder requires each row to be a keyed container (struct/class) — single-value containers (a row that's just a primitive) are not supported."
        )
    }

}
