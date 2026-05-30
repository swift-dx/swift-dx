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

import Instrumentation
import Tracing

// Block-batched typed SELECT path. The per-row `selectStream` makes
// the producer-side `Continuation.yield` and consumer-side `next()`
// the dominant cost: 500k yields/second of a pthread_mutex-backed
// async-stream handoff. This surface yields one array per block
// (typically 100k rows on production workloads), collapsing 500k
// yields/second into ~5 yields/second and removing the per-row
// generic-metadata cache lookup that the async-stream's
// `YieldResult<T, Error>` instantiation drives on every call.
//
// Decoding inside each block is driven by `ClickHouseColumnarDecoder`,
// which resolves each CodingKey to a column-position slot once per
// block (not per row) and indexes typed-column arrays by `Int` on
// every field read. Typed `Date`/`UUID` overloads bypass Codable's
// generic `decode<T>` path entirely.
extension ClickHouseClient {

    /// Block-batched streaming SELECT. The returned
    /// `AsyncThrowingStream` yields one decoded `[T]` array per
    /// server-side Data block (typically 50k-100k rows). Consumers
    /// iterate the outer stream once per block and the inner array
    /// once per row; the inner loop pays no async-stream cost.
    ///
    /// Use this surface when row throughput matters more than the
    /// per-row ergonomics of `selectStream`. On the BenchRow shape
    /// (4 fields) this delivers ~390k rows/second against localhost
    /// ClickHouse — roughly 3x the per-row `selectStream` rate. The
    /// remaining gap to the wire-path ceiling (~1.07M rows/second on
    /// the same shape) is the per-row Codable container allocation
    /// inside Swift's standard library, which this surface cannot
    /// remove without bypassing Codable.
    ///
    /// For the maximum-throughput Codable-free path, see
    /// `selectStreamBuilder`, which trades the Codable convenience
    /// for a caller-supplied row builder closure and runs at the
    /// wire ceiling.
    ///
    /// For per-row streaming ergonomics at the cost of throughput,
    /// see `selectStream`.
    public func selectStreamFast<T: Decodable & Sendable>(
        _ type: T.Type,
        from sql: String,
        settings: [ClickHouseQuerySetting] = [],
        parameters: [ClickHouseQueryParameter] = [],
        keyDecodingStrategy: ClickHouseKeyDecodingStrategy = .useDefaultKeys
    ) -> AsyncThrowingStream<[T], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runFastBlockLoop(
                        T.self,
                        from: sql,
                        settings: settings,
                        parameters: parameters,
                        keyDecodingStrategy: keyDecodingStrategy,
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

    private func runFastBlockLoop<T: Decodable & Sendable>(
        _ type: T.Type,
        from sql: String,
        settings: [ClickHouseQuerySetting],
        parameters: [ClickHouseQueryParameter],
        keyDecodingStrategy: ClickHouseKeyDecodingStrategy,
        continuation: AsyncThrowingStream<[T], Error>.Continuation
    ) async throws {
        for try await block in selectColumns(sql, settings: settings, parameters: parameters) {
            let outcome = try handleFastBlock(T.self, block: block, keyDecodingStrategy: keyDecodingStrategy, continuation: continuation)
            if outcome == .stop { return }
        }
    }

    private enum FastBlockOutcome: Sendable, Equatable {

        case proceed
        case stop
        case decodeAndYield

    }

    private func handleFastBlock<T: Decodable & Sendable>(
        _ type: T.Type,
        block: ClickHouseSelectBlock,
        keyDecodingStrategy: ClickHouseKeyDecodingStrategy,
        continuation: AsyncThrowingStream<[T], Error>.Continuation
    ) throws -> FastBlockOutcome {
        switch preflightOutcome(rowCount: block.rowCount) {
        case .stop: return .stop
        case .proceed: return .proceed
        case .decodeAndYield:
            let rows = try decodeFastBlock(T.self, block: block, keyDecodingStrategy: keyDecodingStrategy)
            return yieldOutcome(rows, continuation: continuation)
        }
    }

    private func preflightOutcome(rowCount: Int) -> FastBlockOutcome {
        if Task.isCancelled { return .stop }
        if rowCount == 0 { return .proceed }
        return .decodeAndYield
    }

    private func yieldOutcome<T: Sendable>(
        _ rows: [T], continuation: AsyncThrowingStream<[T], Error>.Continuation
    ) -> FastBlockOutcome {
        if case .terminated = continuation.yield(rows) { return .stop }
        return .proceed
    }

    // Materialises the full SELECT into a flat `[T]`. Use when the
    // result set fits in memory and the caller wants the canonical
    // bulk-collection shape. Streams blocks internally and decodes
    // each via `ClickHouseColumnarDecoder`.
    public func queryFast<T: Decodable & Sendable>(
        _ type: T.Type,
        from sql: String,
        settings: [ClickHouseQuerySetting] = [],
        parameters: [ClickHouseQueryParameter] = [],
        keyDecodingStrategy: ClickHouseKeyDecodingStrategy = .useDefaultKeys
    ) async throws(ClickHouseError) -> [T] {
        try await ClickHouseError.bridge {
            try await InstrumentationSystem.tracer.withSpan(
                "clickhouse.query", context: .current ?? .topLevel, ofKind: .client
            ) { span in
                span.attributes["db.system.name"] = "clickhouse"
                span.attributes["db.operation.name"] = "SELECT"
                span.attributes["db.query.text"] = String(sql.prefix(256))
                let collected = try await collectFastBlocks(
                    T.self,
                    from: sql,
                    settings: settings,
                    parameters: parameters,
                    keyDecodingStrategy: keyDecodingStrategy
                )
                span.attributes["db.row.count"] = collected.count
                return collected
            }
        }
    }

    private func collectFastBlocks<T: Decodable & Sendable>(
        _ type: T.Type,
        from sql: String,
        settings: [ClickHouseQuerySetting],
        parameters: [ClickHouseQueryParameter],
        keyDecodingStrategy: ClickHouseKeyDecodingStrategy
    ) async throws -> [T] {
        var collected: [T] = []
        for try await block in selectColumns(sql, settings: settings, parameters: parameters) {
            guard block.rowCount > 0 else { continue }
            let rows = try decodeFastBlock(T.self, block: block, keyDecodingStrategy: keyDecodingStrategy)
            collected.append(contentsOf: rows)
        }
        return collected
    }

    private func decodeFastBlock<T: Decodable & Sendable>(
        _ type: T.Type,
        block: ClickHouseSelectBlock,
        keyDecodingStrategy: ClickHouseKeyDecodingStrategy
    ) throws -> [T] {
        let state = try ClickHouseColumnarDecoderState(
            columns: block.columns, keyDecodingStrategy: keyDecodingStrategy
        )
        let decoder = ClickHouseColumnarDecoder(state: state)
        var rows: [T] = []
        rows.reserveCapacity(state.rowCount)
        do {
            for rowIndex in 0..<state.rowCount {
                state.rowIndex = rowIndex
                rows.append(try T(from: decoder))
            }
        } catch {
            throw ClickHouseError.translate(error)
        }
        return rows
    }

}
