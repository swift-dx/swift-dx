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

// Per-row `AsyncSequence` for typed SELECT that runs the block-batched
// columnar decode path underneath. The iterator pulls one
// `ClickHouseSelectBlock` from the upstream wire stream, decodes the
// whole block into a `[T]` buffer using `ClickHouseColumnarDecoder`,
// and serves `next()` calls from that buffer until it drains. Only
// then does the iterator await the next block. The async hop and the
// `Decoder` plumbing therefore amortise across the block (typically
// 50k-100k rows) instead of paying per row.
//
// Compared with `selectStream` (which yields per row through an
// `AsyncThrowingStream` continuation guarded by a pthread mutex), the
// per-row cost here collapses to a buffer-indexed array read plus the
// generic-call overhead of `AsyncIteratorProtocol.next`. On the
// `BenchRow` shape (4 fields) this matches the block-batched
// `selectStreamFast` rate within measurement noise while preserving
// the per-row consumer ergonomics of `for try await row in stream`.
//
// The associated `Failure` type stays `any Error` to keep the public
// iteration shape identical to `AsyncThrowingStream<T, Error>`. The
// upstream `selectColumns` stream surfaces `ClickHouseError` values
// through that `any Error` channel; consumers who want the typed
// variant can downcast at the catch site.
public struct ClickHouseRowSequence<T: Decodable & Sendable>: AsyncSequence, Sendable {

    public typealias Element = T

    let client: ClickHouseClient
    let sql: String
    let settings: [ClickHouseQuerySetting]
    let parameters: [ClickHouseQueryParameter]
    let keyDecodingStrategy: ClickHouseKeyDecodingStrategy

    public func makeAsyncIterator() -> Iterator {
        let blockStream = client.selectColumns(sql, settings: settings, parameters: parameters)
        return Iterator(blocks: blockStream.makeAsyncIterator(), keyDecodingStrategy: keyDecodingStrategy)
    }

    public struct Iterator: AsyncIteratorProtocol {

        var blocks: AsyncThrowingStream<ClickHouseSelectBlock, Error>.AsyncIterator
        let keyDecodingStrategy: ClickHouseKeyDecodingStrategy
        var buffer: ContiguousArray<T> = []
        var cursor: Int = 0

        public mutating func next() async throws(any Error) -> T? {
            if cursor < buffer.count {
                let row = buffer[cursor]
                cursor += 1
                return row
            }
            return try await loadNextBlockAndReturnFirstRow()
        }

        private mutating func loadNextBlockAndReturnFirstRow() async throws -> T? {
            while let block = try await blocks.next() {
                if block.rowCount == 0 { continue }
                buffer = try ClickHouseRowBlockDecoder.decode(T.self, block: block, keyDecodingStrategy: keyDecodingStrategy)
                cursor = 1
                return buffer[0]
            }
            return nil
        }

    }

}

enum ClickHouseRowBlockDecoder {

    static func decode<T: Decodable>(
        _ type: T.Type,
        block: ClickHouseSelectBlock,
        keyDecodingStrategy: ClickHouseKeyDecodingStrategy
    ) throws -> ContiguousArray<T> {
        let state = try ClickHouseColumnarDecoderState(
            columns: block.columns, keyDecodingStrategy: keyDecodingStrategy
        )
        let decoder = ClickHouseColumnarDecoder(state: state)
        let count = state.rowCount
        do {
            return try ContiguousArray<T>(unsafeUninitializedCapacity: count) { storage, initialized in
                for rowIndex in 0..<count {
                    state.rowIndex = rowIndex
                    let row = try T(from: decoder)
                    storage.initializeElement(at: rowIndex, to: row)
                }
                initialized = count
            }
        } catch {
            throw ClickHouseError.translate(error)
        }
    }

}
