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

// Codable-based decoder that materializes `[ClickHouseSelectColumn]`
// from a SELECT result into `[T]` where T conforms to `Decodable`.
// The supported and rejected sets mirror `ClickHouseRowEncoder`.
//
// Supported field types:
//   - String, Bool
//   - Int8/16/32/64, UInt8/16/32/64 (Swift `Int`/`UInt` rejected:
//     platform-dependent width)
//   - Float (Float32), Double (Float64)
//   - Foundation.Date (read from ClickHouse DateTime / DateTime64)
//   - Foundation.UUID
//   - Optional<T> for every supported `T` (Nullable(T) on the wire,
//     including the case where a non-Optional field reads from a
//     Nullable column and surfaces `valueNotFound` if the row is null)
//
// Rejected (throws):
//   - Maps ([String: String], etc.)
//   - Arrays of any element type at the row level
//   - Nested Decodable structs / single-value containers
//
// Type mismatches surface as `DecodingError.typeMismatch` (Codable's
// standard error catalog), missing columns as
// `DecodingError.keyNotFound`, so standard Codable error handling at
// the call site works.
public final class ClickHouseRowDecoder: Sendable {

    public let keyDecodingStrategy: ClickHouseKeyDecodingStrategy

    public init(keyDecodingStrategy: ClickHouseKeyDecodingStrategy = .useDefaultKeys) {
        self.keyDecodingStrategy = keyDecodingStrategy
    }

    public func decode<T: Decodable & Sendable>(_ type: T.Type, from columns: [ClickHouseSelectColumn]) throws(ClickHouseError) -> [T] {
        do {
            return try decodeRaw(type, from: columns)
        } catch {
            throw ClickHouseError.translate(error)
        }
    }

    // Routes through the columnar fast-path decoder: per-block slot
    // cache, reused keyed-container instance, parallel-array key
    // lookup. The per-field hot path drops the dictionary probe used
    // by the legacy per-row storage and the per-row decoder/container
    // allocation pair.
    private func decodeRaw<T: Decodable & Sendable>(_ type: T.Type, from columns: [ClickHouseSelectColumn]) throws -> [T] {
        let state = try ClickHouseColumnarDecoderState(
            columns: columns, keyDecodingStrategy: keyDecodingStrategy
        )
        let decoder = ClickHouseColumnarDecoder(state: state)
        var result: [T] = []
        result.reserveCapacity(state.rowCount)
        for rowIndex in 0..<state.rowCount {
            state.rowIndex = rowIndex
            result.append(try T(from: decoder))
        }
        return result
    }

    // Streaming decode: invokes `body` once per row in document order
    // and stops as soon as the body returns false. Reuses one
    // `ClickHouseColumnarDecoder` and its cached keyed container
    // across every row in the block. Peak memory is one `T` plus the
    // shared per-block state — the row stream never materializes a
    // full `[T]`.
    //
    // The body's return value is the producer-side cancellation
    // signal: `false` means "consumer abandoned, stop iterating". The
    // semantics mirror `AsyncThrowingStream.Continuation.YieldResult`
    // so the caller can map a `.terminated` yield to `false`.
    public func decodeStreaming<T: Decodable & Sendable>(
        _ type: T.Type,
        from columns: [ClickHouseSelectColumn],
        body: (T) throws -> Bool
    ) throws {
        let state = try ClickHouseColumnarDecoderState(
            columns: columns, keyDecodingStrategy: keyDecodingStrategy
        )
        let decoder = ClickHouseColumnarDecoder(state: state)
        for rowIndex in 0..<state.rowCount {
            state.rowIndex = rowIndex
            let row = try T(from: decoder)
            if try body(row) == false {
                return
            }
        }
    }

}
