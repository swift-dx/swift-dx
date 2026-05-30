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
// into the columnar `[ClickHouseColumnEntry]` representation the
// native TCP path uses for INSERT.
//
// Supported field types:
//   - String, Bool
//   - Int8/16/32/64, UInt8/16/32/64 (Swift `Int`/`UInt` rejected:
//     platform-dependent width would split a column across
//     architectures, so callers must pick a fixed-width alternative)
//   - Float (Float32), Double (Float64)
//   - Foundation.Date (encoded as ClickHouse DateTime)
//   - Foundation.UUID
//   - Optional<T> for every supported `T` (lowered to Nullable(T))
//
// Rejected with `rowEncoderUnsupportedType`:
//   - Maps ([String: String], etc.)
//   - Arrays of any element type at the row level
//   - Nested Codable structs / single-value containers
//
// The first row establishes each column's name + Swift type. Every
// subsequent row must produce the same column set with matching
// types. Type conflicts surface as `rowEncoderColumnTypeMismatch`;
// row N missing columns from row 0 surfaces as
// `rowEncoderRowMissingColumns`.
public final class ClickHouseRowEncoder: Sendable {

    public let keyEncodingStrategy: ClickHouseKeyEncodingStrategy

    public init(keyEncodingStrategy: ClickHouseKeyEncodingStrategy = .useDefaultKeys) {
        self.keyEncodingStrategy = keyEncodingStrategy
    }

    public func encode<T: Encodable & Sendable>(_ rows: [T]) throws(ClickHouseError) -> [ClickHouseColumnEntry] {
        do {
            return try encodeRaw(rows)
        } catch {
            throw ClickHouseError.translate(error)
        }
    }

    private func encodeRaw<T: Encodable & Sendable>(_ rows: [T]) throws -> [ClickHouseColumnEntry] {
        let storage = ClickHouseRowColumnStorage()
        for row in rows {
            try storage.beginRow()
            let encoder = ClickHouseRowEncoderImpl(storage: storage, keyEncodingStrategy: keyEncodingStrategy)
            try row.encode(to: encoder)
            try storage.endRow()
        }
        return storage.materialize()
    }

}
