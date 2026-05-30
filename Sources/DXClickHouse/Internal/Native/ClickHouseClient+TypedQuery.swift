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

// Typed SELECT path: runs the query and decodes each columnar block
// into `Decodable` row models via `ClickHouseRowDecoder`. This is the
// layer the `ClickHouse` facade routes to.
//
// `query` collects the full result and opens a `clickhouse.query`
// span. `selectStream` yields rows lazily and never materializes the
// whole set; it carries no span because a stream's lifetime is the
// consumer's, not a single bounded operation.
extension ClickHouseClient {

    public func query<T: Decodable & Sendable>(_ type: T.Type, from sql: String, settings: [ClickHouseQuerySetting] = [], parameters: [ClickHouseQueryParameter] = [], keyDecodingStrategy: ClickHouseKeyDecodingStrategy = .useDefaultKeys) async throws(ClickHouseError) -> [T] {
        try await ClickHouseError.bridge {
            try await InstrumentationSystem.tracer.withSpan(
                "clickhouse.query", context: .current ?? .topLevel, ofKind: .client
            ) { span in
                span.attributes["db.system.name"] = "clickhouse"
                span.attributes["db.operation.name"] = "SELECT"
                span.attributes["db.query.text"] = String(sql.prefix(256))
                let decoder = ClickHouseRowDecoder(keyDecodingStrategy: keyDecodingStrategy)
                var allRows: [T] = []
                for try await block in selectColumns(sql, settings: settings, parameters: parameters) {
                    guard block.rowCount > 0 else { continue }
                    let rows = try decoder.decode(T.self, from: block.columns)
                    allRows.append(contentsOf: rows)
                }
                span.attributes["db.row.count"] = allRows.count
                return allRows
            }
        }
    }

    /// Per-row streaming SELECT. The returned `AsyncThrowingStream`
    /// yields one decoded `T` per row. Ergonomic for `for try await row in
    /// client.selectStream(...)` loops. Each row passes through the async
    /// stream's continuation, so the throughput ceiling on a typical
    /// 4-field row is roughly 130k-150k rows/second — the per-row
    /// stream handoff (pthread-mutex-backed continuation) is the
    /// dominant cost.
    ///
    /// For higher throughput at the cost of slightly different
    /// ergonomics, use `selectStreamFast` which yields one `[T]` array
    /// per server-side block. The per-row cost there is paid only by
    /// the consumer-side `for row in batch` loop without any async
    /// handoff. On the BenchRow shape (4 fields) `selectStreamFast`
    /// runs ~3x faster than `selectStream`.
    ///
    /// For the maximum-throughput Codable-free path, see
    /// `selectStreamBuilder` (also yields one `[T]` array per block,
    /// uses a caller-supplied row builder closure instead of Codable).
    public func selectStream<T: Decodable & Sendable>(_ type: T.Type, from sql: String, settings: [ClickHouseQuerySetting] = [], parameters: [ClickHouseQueryParameter] = [], keyDecodingStrategy: ClickHouseKeyDecodingStrategy = .useDefaultKeys) -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let decoder = ClickHouseRowDecoder(keyDecodingStrategy: keyDecodingStrategy)
                    var consumerAbandoned = false
                    for try await block in selectColumns(sql, settings: settings, parameters: parameters) {
                        if Task.isCancelled { return }
                        guard block.rowCount > 0 else { continue }
                        try decoder.decodeStreaming(T.self, from: block.columns) { row in
                            if case .terminated = continuation.yield(row) {
                                consumerAbandoned = true
                                return false
                            }
                            return true
                        }
                        if consumerAbandoned { return }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

}
