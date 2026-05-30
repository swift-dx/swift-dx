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

// Maximum-performance typed SELECT path that bypasses Codable
// entirely. The caller supplies a row-builder closure that receives
// the columnar block plus a row index and returns a `T`. Each
// per-row call inlines into a sequence of typed-array subscripts —
// no `Decoder`, no `KeyedDecodingContainer`, no per-row
// metatype lookup, no `as? T` casts.
//
// Use this surface when the Codable path's overhead is the
// throughput ceiling. The Codable `selectStream` /
// `selectStreamFast` surfaces remain the recommended default for
// ergonomic call sites that do not need the absolute floor.
extension ClickHouseClient {

    public typealias ClickHouseRowBuilder<T> = @Sendable (ClickHouseSelectBlock, Int) throws -> T

    // Streams one `[T]` array per server-side Data block. Each
    // block-array is constructed by repeatedly invoking
    // `rowBuilder(block, rowIndex)`. The row builder runs on the
    // consumer-side decode task, not on the NIO event loop.
    public func selectStreamBuilder<T: Sendable>(
        _ type: T.Type,
        from sql: String,
        settings: [ClickHouseQuerySetting] = [],
        parameters: [ClickHouseQueryParameter] = [],
        rowBuilder: @escaping ClickHouseRowBuilder<T>
    ) -> AsyncThrowingStream<[T], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runBuilderBlockLoop(
                        T.self,
                        from: sql,
                        settings: settings,
                        parameters: parameters,
                        rowBuilder: rowBuilder,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runBuilderBlockLoop<T: Sendable>(
        _ type: T.Type,
        from sql: String,
        settings: [ClickHouseQuerySetting],
        parameters: [ClickHouseQueryParameter],
        rowBuilder: @escaping ClickHouseRowBuilder<T>,
        continuation: AsyncThrowingStream<[T], Error>.Continuation
    ) async throws {
        for try await block in selectColumns(sql, settings: settings, parameters: parameters) {
            let outcome = try handleBuilderBlock(block: block, rowBuilder: rowBuilder, continuation: continuation)
            if outcome == .stop { return }
        }
    }

    private enum BuilderBlockOutcome: Sendable, Equatable {

        case proceed
        case stop
        case decodeAndYield

    }

    private func handleBuilderBlock<T: Sendable>(
        block: ClickHouseSelectBlock,
        rowBuilder: ClickHouseRowBuilder<T>,
        continuation: AsyncThrowingStream<[T], Error>.Continuation
    ) throws -> BuilderBlockOutcome {
        switch builderPreflightOutcome(rowCount: block.rowCount) {
        case .stop: return .stop
        case .proceed: return .proceed
        case .decodeAndYield:
            let rows = try buildRows(block: block, rowBuilder: rowBuilder)
            return builderYieldOutcome(rows, continuation: continuation)
        }
    }

    private func builderPreflightOutcome(rowCount: Int) -> BuilderBlockOutcome {
        if Task.isCancelled { return .stop }
        if rowCount == 0 { return .proceed }
        return .decodeAndYield
    }

    private func builderYieldOutcome<T: Sendable>(
        _ rows: [T], continuation: AsyncThrowingStream<[T], Error>.Continuation
    ) -> BuilderBlockOutcome {
        if case .terminated = continuation.yield(rows) { return .stop }
        return .proceed
    }

    private func buildRows<T: Sendable>(
        block: ClickHouseSelectBlock,
        rowBuilder: ClickHouseRowBuilder<T>
    ) throws -> [T] {
        // Skip per-append COW uniqueness check + slot zero-init by
        // writing into an uninitialised buffer directly. The closure
        // is the only writer between allocation and return, so
        // `initialized = count` once every slot has been initialised
        // satisfies the contract on Array.init(unsafeUninitializedCapacity:).
        // If `rowBuilder` throws mid-block, the partially-written
        // entries are leaked — matching the existing `Array.append`
        // semantics, which also do not undo prior appends on throw —
        // and `RealEventProjection`-style POD rows have no destructor
        // cost from this. For class-typed `T` the caller already pays
        // a retain per row inside `rowBuilder`, and a mid-block throw
        // would orphan those retains either way.
        let count = block.rowCount
        return try [T](unsafeUninitializedCapacity: count) { storage, initialized in
            for rowIndex in 0..<count {
                let row = try rowBuilder(block, rowIndex)
                storage.initializeElement(at: rowIndex, to: row)
            }
            initialized = count
        }
    }

}
