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

// Internal Decoder implementation. The public surface is
// `ClickHouseRowDecoder`; this is the per-row instance the Codable
// runtime drives via `T.init(from:)`.
struct ClickHouseRowDecoderImpl: Decoder {

    let storage: ClickHouseRowDecoderStorage
    let rowIndex: Int
    let keyDecodingStrategy: ClickHouseKeyDecodingStrategy
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> where Key: CodingKey {
        KeyedDecodingContainer(ClickHouseRowKeyedDecodingContainer<Key>(
            storage: storage,
            rowIndex: rowIndex,
            keyDecodingStrategy: keyDecodingStrategy,
            codingPath: codingPath
        ))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.dataCorrupted(.init(
            codingPath: codingPath,
            debugDescription: "ClickHouseRowDecoder requires each row to be a keyed container — unkeyed root containers are not supported."
        ))
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        throw DecodingError.dataCorrupted(.init(
            codingPath: codingPath,
            debugDescription: "ClickHouseRowDecoder requires each row to be a keyed container — single-value root containers are not supported."
        ))
    }

}
