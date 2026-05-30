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
import NIOCore
import Tracing

// Long-lived ClickHouse client built on a NIO connection pool. One
// instance per logical cluster (or per (cluster, credentials) pair)
// is the intended pattern; instances should be reused across the
// service lifetime rather than created per request.
//
// `Sendable` is compiler-derived: the only stored property is an
// actor (`ClickHouseConnectionPool`), so all mutable state lives
// behind actor isolation and the compiler can verify thread-safety
// without an `@unchecked` escape hatch.
//
// Two coexisting layers of API:
//
//   1. Low-level methods on this class (`select`, `insert`, `execute`,
//      `ping`, `serverInfo`, `warmUp`, `shutdown`) plus extension
//      methods for catalog, scalar, retry, typed-select, and
//      streaming insert. These take/return wire-shaped types
//      (`ClickHouseColumnEntry`, `ClickHouseSelectBlock`).
//
//   2. The `ClickHouse` facade in Codable/ClickHouse.swift. Singleton-
//      hosted, accepts any `Encodable`/`Decodable` row, pipes through
//      `ClickHouseRowEncoder`/`ClickHouseRowDecoder`. The recommended
//      surface for application code that has typed row models.
//
// On dealloc the deinit fires a fire-and-forget shutdown task as a
// safety net for forgotten cleanup, but services should call
// `shutdown()` explicitly so the teardown is observable.
public final class ClickHouseClient: Sendable {

    let pool: ClickHouseConnectionPool

    init(poolConfiguration: ClickHouseConnectionPool.Configuration) {
        self.pool = ClickHouseConnectionPool(configuration: poolConfiguration)
    }

    public convenience init(configuration: Configuration) {
        self.init(poolConfiguration: configuration.poolConfiguration)
    }

    func select(
        _ sql: String,
        settings: [ClickHouseQuerySetting] = [],
        parameters: [ClickHouseQueryParameter] = [],
        onProgress: @escaping @Sendable (ClickHouseProgress) -> Void = ClickHouseConnection.noProgressCallback
    ) -> AsyncThrowingStream<ClickHouseBlock, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.pool.withConnection { connection in
                        for try await block in connection.selectBlocks(
                            sql, settings: settings, parameters: parameters, onProgress: onProgress
                        ) {
                            if case .terminated = continuation.yield(block) {
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func insert(
        _ sql: String,
        blocks: [ClickHouseBlock],
        settings: [ClickHouseQuerySetting] = [],
        parameters: [ClickHouseQueryParameter] = [],
        onProgress: @escaping @Sendable (ClickHouseProgress) -> Void = ClickHouseConnection.noProgressCallback
    ) async throws {
        try await pool.withConnection { connection in
            try await connection.insertBlocks(
                sql, blocks: blocks, settings: settings, parameters: parameters, onProgress: onProgress
            )
        }
    }

    public func execute(_ sql: String, settings: [ClickHouseQuerySetting] = [], parameters: [ClickHouseQueryParameter] = []) async throws(ClickHouseError) {
        try await executeReportingProgress(sql, settings: settings, parameters: parameters, onProgress: { _ in })
    }

    public func executeReportingProgress(_ sql: String, settings: [ClickHouseQuerySetting] = [], parameters: [ClickHouseQueryParameter] = [], onProgress: @escaping @Sendable (ClickHouseProgress) -> Void) async throws(ClickHouseError) {
        try await ClickHouseError.bridge {
            try await InstrumentationSystem.tracer.withSpan(
                "clickhouse.execute", context: .current ?? .topLevel, ofKind: .client
            ) { span in
                span.attributes["db.system.name"] = "clickhouse"
                // First SQL keyword is the operation name, e.g. CREATE,
                // DROP, TRUNCATE, ALTER, INSERT, OPTIMIZE.
                let firstWord = sql.split(separator: " ", maxSplits: 1).first.map(String.init) ?? "EXECUTE"
                span.attributes["db.operation.name"] = firstWord.uppercased()
                span.attributes["db.query.text"] = String(sql.prefix(256))
                try await pool.withConnection { connection in
                    try await connection.execute(
                        sql, settings: settings, parameters: parameters, onProgress: onProgress
                    )
                }
            }
        }
    }

    public func ping() async throws(ClickHouseError) {
        try await ClickHouseError.bridge {
            try await pool.withConnection { connection in
                try await connection.ping()
            }
        }
    }

    // Pre-open connections so the first burst of queries doesn't pay the
    // TCP+TLS+handshake cost. The effective count is capped by both
    // `maxConnections` and `maxIdleConnections` — opening more would
    // waste connections (the pool would close them on release once idle
    // exceeds the cap).
    //
    // Best-effort: if any connection fails to open, the error propagates
    // and connections opened so far are released back to the pool. The
    // caller can decide whether to retry or proceed with whatever was
    // opened before the failure.
    public func warmUp(connections: Int) async throws(ClickHouseError) {
        let effectiveCount = await pool.effectiveWarmupCount(requested: connections)
        guard effectiveCount > 0 else { return }
        let opened = try await acquireWarmupConnections(count: effectiveCount)
        await releaseWarmupConnections(opened)
    }

    private func acquireWarmupConnections(count: Int) async throws(ClickHouseError) -> [ClickHouseConnection] {
        var opened: [ClickHouseConnection] = []
        opened.reserveCapacity(count)
        do {
            try await acquireInto(&opened, count: count)
        } catch let error as ClickHouseError {
            await releaseWarmupConnections(opened)
            throw error
        } catch {
            await releaseWarmupConnections(opened)
            throw warmUpUnknownFailure(error: error)
        }
        return opened
    }

    private func acquireInto(_ opened: inout [ClickHouseConnection], count: Int) async throws {
        for _ in 0..<count {
            let connection = try await pool.acquire()
            opened.append(connection)
        }
    }

    private func releaseWarmupConnections(_ opened: [ClickHouseConnection]) async {
        for connection in opened {
            await pool.release(connection)
        }
    }

    private func warmUpUnknownFailure(error: Error) -> ClickHouseError {
        .codableDecodingFailure(
            kind: .unknown,
            typeName: String(reflecting: type(of: error)),
            codingPath: "",
            debugDescription: String(reflecting: error)
        )
    }

    public func serverInfo() async throws(ClickHouseError) -> ClickHouseServerInfo {
        try await ClickHouseError.bridge {
            try await pool.withConnection { connection in
                connection.metadata.publicServerInfo
            }
        }
    }

    public func shutdown() async {
        await pool.shutdown()
    }

    public func poolStats() async -> ClickHouseConnectionPoolStats {
        await pool.stats()
    }

    // Best-effort cleanup if the caller drops the client without
    // calling `shutdown()`. The pool ref is captured into a Task so
    // it survives long enough to close idle connections and cancel
    // the background eviction loop. If `shutdown()` was already
    // called, the inner state is empty and this is a cheap no-op.
    //
    // Callers that care about deterministic teardown timing should
    // still call `shutdown()` explicitly before dropping the client;
    // this deinit is a safety net for forgotten cleanup, not a
    // replacement for it.
    deinit {
        let pool = self.pool
        Task { await pool.shutdown() }
    }

}
