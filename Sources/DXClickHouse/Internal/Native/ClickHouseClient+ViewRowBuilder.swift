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

// Maximum-performance typed SELECT path that bypasses Codable entirely
// and reads payload bytes directly from the per-block arena. The
// caller supplies a row-builder closure that receives the
// `ClickHouseBlockStringView` projection plus a row index and returns
// a `T`. Each per-row call inlines into a sequence of arena-backed
// view reads — no `Decoder`, no `KeyedDecodingContainer`, no per-row
// Swift `String` allocation for the columns the row builder reads
// through views.
//
// Lifetime contract for the view-builder closure:
//
//   - `ClickHouseBlockStringView` and every `ClickHouseStringView` /
//     `ClickHouseFixedStringView` / `ClickHouseArrayOfFixedStringView`
//     / `ClickHouseMapStringStringView` obtained from it are valid for
//     the duration of the closure invocation only.
//
//   - The arenas backing the views are reference-counted, so a view
//     that escapes will keep the bytes alive — but escaping a view
//     into the returned `T` (or into shared state) defeats the entire
//     allocation-avoidance goal of this path. Callers MUST NOT capture
//     a view inside `T`. Materialise to an owning `String` via
//     `view.asString()` if the row needs to outlive the closure.
//
//   - `T` itself is `Sendable` and crosses concurrency boundaries
//     freely once constructed; the lifetime constraint applies to the
//     view types only.
//
// Use this surface for filter-heavy or projection-heavy workloads on
// payload columns where most rows reduce to a typed aggregate (count,
// sum, hash, bool) without materialising every payload into a Swift
// `String`. For "decode every row into a struct that owns its
// strings" workloads the standard `selectStream` / `selectStreamFast`
// / `selectStreamBuilder` paths remain preferable.
extension ClickHouseClient {

    public typealias ClickHouseViewRowBuilder<T> = @Sendable (ClickHouseBlockStringView, Int) throws -> T

    // Streams one `[T]` array per server-side Data block. Each block
    // is decoded via the zero-allocation `selectStringColumns` view
    // projection and the supplied `rowBuilder` runs once per row to
    // produce `T`. The row builder executes on the consumer-side
    // decode task, not on the NIO event loop.
    public func selectRowsBuilder<T: Sendable>(
        _ type: T.Type,
        from sql: String,
        settings: [ClickHouseQuerySetting] = [],
        parameters: [ClickHouseQueryParameter] = [],
        rowBuilder: @escaping ClickHouseViewRowBuilder<T>
    ) -> AsyncThrowingStream<[T], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runViewBuilderBlockLoop(
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

    private func runViewBuilderBlockLoop<T: Sendable>(
        _ type: T.Type,
        from sql: String,
        settings: [ClickHouseQuerySetting],
        parameters: [ClickHouseQueryParameter],
        rowBuilder: @escaping ClickHouseViewRowBuilder<T>,
        continuation: AsyncThrowingStream<[T], Error>.Continuation
    ) async throws {
        for try await block in selectStringColumns(sql, settings: settings, parameters: parameters) {
            let outcome = try handleViewBuilderBlock(block: block, rowBuilder: rowBuilder, continuation: continuation)
            if outcome == .stop { return }
        }
    }

    private enum ViewBuilderBlockOutcome: Sendable, Equatable {

        case proceed
        case stop
        case decodeAndYield

    }

    private func handleViewBuilderBlock<T: Sendable>(
        block: ClickHouseBlockStringView,
        rowBuilder: ClickHouseViewRowBuilder<T>,
        continuation: AsyncThrowingStream<[T], Error>.Continuation
    ) throws -> ViewBuilderBlockOutcome {
        switch viewBuilderPreflightOutcome(rowCount: block.rowCount) {
        case .stop: return .stop
        case .proceed: return .proceed
        case .decodeAndYield:
            let rows = try buildViewRows(block: block, rowBuilder: rowBuilder)
            return viewBuilderYieldOutcome(rows, continuation: continuation)
        }
    }

    private func viewBuilderPreflightOutcome(rowCount: Int) -> ViewBuilderBlockOutcome {
        if Task.isCancelled { return .stop }
        if rowCount == 0 { return .proceed }
        return .decodeAndYield
    }

    private func viewBuilderYieldOutcome<T: Sendable>(
        _ rows: [T], continuation: AsyncThrowingStream<[T], Error>.Continuation
    ) -> ViewBuilderBlockOutcome {
        if case .terminated = continuation.yield(rows) { return .stop }
        return .proceed
    }

    private func buildViewRows<T: Sendable>(
        block: ClickHouseBlockStringView,
        rowBuilder: ClickHouseViewRowBuilder<T>
    ) throws -> [T] {
        // Mirrors the eager-allocate path used by `selectStreamBuilder`:
        // an uninitialised storage buffer the closure fills in row
        // order, with the row builder running on the consumer-side
        // decode task. The arena handles inside `block` keep the wire
        // bytes alive for every per-row call.
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
