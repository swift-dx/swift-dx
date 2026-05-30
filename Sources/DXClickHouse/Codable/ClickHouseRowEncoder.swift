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

// Codable-based encoder that converts an array of `Encodable` rows
// into the columnar `[ClickHouseNamedColumn]` representation the
// raw INSERT path uses on the wire.
//
// Supported field types:
//   * String, Bool
//   * Int8/16/32/64, UInt8/16/32/64
//   * Float (Float32), Double (Float64)
//   * Foundation.Date (encoded as ClickHouse DateTime, UInt32 seconds)
//   * Foundation.UUID (encoded as ClickHouse UUID, 16 bytes)
//   * Optional<T> for each supported `T` (lowered to Nullable(T))
//
// Swift's platform-dependent `Int` and `UInt` are intentionally
// rejected: the column width on the wire would silently change between
// 32-bit and 64-bit hosts. Callers must pick a fixed-width alternative.
//
// The first row establishes each column's name + Swift type. Every
// subsequent row must produce the same column set with matching types.
// Type conflicts surface as `.encoderColumnTypeMismatch`; row N missing
// columns that row 0 declared surfaces as `.encoderRowMissingColumns`.
public final class ClickHouseRowEncoder: Sendable {

    public init() {}

    public func encode<T: Encodable & Sendable>(_ rows: [T]) throws(ClickHouseError) -> [ClickHouseNamedColumn] {
        let storage = ClickHouseRowEncoderStorage()
        do {
            for row in rows {
                storage.beginRow()
                let encoder = ClickHouseRowEncoderImpl(storage: storage)
                try row.encode(to: encoder)
                try storage.endRow()
            }
        } catch let error as ClickHouseError {
            throw error
        } catch {
            throw .protocolError(stage: "ClickHouseRowEncoder", message: "\(error)")
        }
        return storage.materialize()
    }
}

// Per-row Encoder instance handed to the Codable runtime. The runtime
// asks for a keyed container; the container routes per-field encode
// calls into the storage's typed accumulators.
struct ClickHouseRowEncoderImpl: Encoder {

    let storage: ClickHouseRowEncoderStorage
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> where Key: CodingKey {
        KeyedEncodingContainer(ClickHouseRowKeyedContainer<Key>(storage: storage, codingPath: codingPath))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        ClickHouseRowRejectingContainer(codingPath: codingPath)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        ClickHouseRowRejectingContainer(codingPath: codingPath)
    }
}
