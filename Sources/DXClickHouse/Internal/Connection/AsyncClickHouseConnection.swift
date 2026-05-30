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

import Dispatch

// Async/await wrapper around the synchronous ClickHouseConnection.
// The underlying POSIX socket transport stays single-threaded on a
// dedicated serial DispatchQueue ("the worker"). Every public async
// method posts a work item to that queue and bridges the result back
// through a CheckedContinuation. The actor isolation guarantees that
// only one outstanding operation is in flight on a given connection at
// any time; the queue itself serialises send/recv ordering so the wire
// protocol invariants the sync transport relies on are preserved.
//
// Receive paths come in two shapes:
//
//   * `drainBlocks()` — single `await` that drains the entire result
//     set on the worker and returns the cumulative row count. This is
//     the cheapest async surface: one continuation hop per query.
//
//   * `receiveBlocks()` — yields one `[UInt8]` per non-empty data
//     block via AsyncThrowingStream. The worker copies each block body
//     out of the arena into a heap-owned `[UInt8]` and yields it. This
//     adds a per-block memcpy compared to the sync callback path; use
//     `drainBlocks()` when the bytes are not needed.
//
// The actor wraps a final-class transport box so the worker queue can
// reach the sync connection without crossing actor isolation on every
// wire-byte touch — actor isolation on every recv() would defeat the
// purpose of measuring the async overhead in isolation.
public final actor AsyncClickHouseConnection {

    private let worker: DispatchQueue
    private let transport: TransportBox

    public nonisolated var serverInfo: ClickHouseConnection.ServerInfo {
        transport.connection.serverInfo
    }

    public init(
        host: String,
        port: Int,
        user: String = "default",
        password: String = "",
        database: String = "default",
        reconnectionPolicy: ReconnectionPolicy = .default
    ) async throws {
        let worker = DispatchQueue(label: "swift-dx.async-raw-clickhouse", qos: .userInitiated)
        self.worker = worker
        let connection: ClickHouseConnection = try await withCheckedThrowingContinuation { continuation in
            worker.async {
                do {
                    let made = try ClickHouseConnection(
                        host: host,
                        port: port,
                        user: user,
                        password: password,
                        database: database,
                        reconnectionPolicy: reconnectionPolicy
                    )
                    continuation.resume(returning: made)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        self.transport = TransportBox(connection: connection)
    }

    public func sendQuery(_ sql: String) async throws {
        let transport = self.transport
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            worker.async {
                do {
                    try transport.connection.sendQuery(sql)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // Full-surface async send: query ID, settings, parameters bridged
    // to the worker thread. Caller awaits one continuation hop per
    // call.
    public func sendQuery(
        _ sql: String,
        queryID: String,
        settings: ClickHouseQuerySettings = .empty,
        parameters: ClickHouseQueryParameters = .empty
    ) async throws {
        let transport = self.transport
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            worker.async {
                do {
                    try transport.connection.sendQuery(
                        sql,
                        queryID: queryID,
                        settings: settings,
                        parameters: parameters
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // Round-trip Ping → Pong. Pool preflight uses this to validate a
    // recycled connection before handing it back to a caller.
    public func ping() async throws {
        let transport = self.transport
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            worker.async {
                do {
                    try transport.connection.ping()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // One-shot drain: posts a single work item that runs the sync receive
    // loop end-to-end. The continuation resumes exactly once when the
    // server signals EndOfStream. This is the floor-shape async surface
    // — one hop, no per-block coordination.
    public func drainBlocks() async throws -> Int {
        let transport = self.transport
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            worker.async {
                do {
                    let rows = try transport.connection.receiveBlocksDrain { _, _, _ in }
                    continuation.resume(returning: rows)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // Drain with the full callback set bridged to the worker. The
    // callbacks fire on the worker queue; callers that need to mutate
    // outside state from inside a callback are responsible for their
    // own synchronisation.
    public func drainBlocks(
        onProgress: @escaping @Sendable (ClickHouseProgress) -> Void = { _ in },
        onProfileInfo: @escaping @Sendable (ClickHouseProfileInfo) -> Void = { _ in },
        onProfileEvents: @escaping @Sendable (ClickHouseProfileEvents) -> Void = { _ in }
    ) async throws -> Int {
        let transport = self.transport
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            worker.async {
                do {
                    let callbacks = ClickHouseConnection.ReceiveCallbacks(
                        onProgress: onProgress,
                        onProfileInfo: onProfileInfo,
                        onProfileEvents: onProfileEvents
                    )
                    let rows = try transport.connection.receiveBlocksDrain(callbacks: callbacks) { _, _, _ in }
                    continuation.resume(returning: rows)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // Scalar UInt64 round-trip. One continuation hop per call.
    public func receiveScalarUInt64() async throws -> UInt64 {
        let transport = self.transport
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt64, Error>) in
            worker.async {
                do {
                    let value = try transport.connection.receiveScalarUInt64()
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // String-extracting drain: copies String / FixedString column bodies
    // out of the arena per block, returns total rows + total body bytes.
    // The copy itself happens on the worker so the bytes survive the
    // async hop; this matches the sync `receiveBlocksExtractingStrings`
    // shape used by `select_full_scan_proj_view`.
    public func extractStringsDrain() async throws -> (rows: Int, bytes: Int) {
        let transport = self.transport
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Int, Int), Error>) in
            worker.async {
                do {
                    var bytes = 0
                    let rows = try transport.connection.receiveBlocksExtractingStrings { _, _, _, bodies in
                        for body in bodies {
                            bytes += body.count
                        }
                    }
                    continuation.resume(returning: (rows, bytes))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // Per-block streaming: yields one `[UInt8]` per non-empty Data
    // block. The worker copies each block body out of the arena into a
    // heap-owned `[UInt8]` (Sendable, lifetime-safe across the async
    // hop) and yields it to the stream. The original spec sketch named
    // `UnsafeRawBufferPointer` here; with AsyncThrowingStream the
    // stream's internal buffer can hold multiple yielded elements
    // before the consumer iterates them, so any pointer would need
    // per-element retained backing storage that survives the buffer's
    // lifetime. `[UInt8]` carries its own storage with the same
    // lifetime guarantee at zero additional ceremony, and the wrapper
    // would be the same memcpy cost either way.
    public nonisolated func receiveBlocks() -> AsyncThrowingStream<[UInt8], Error> {
        let worker = self.worker
        let transport = self.transport
        return AsyncThrowingStream { continuation in
            worker.async {
                do {
                    _ = try transport.connection.receiveBlocks { _, body in
                        var copy = [UInt8](repeating: 0, count: body.count)
                        if let source = body.baseAddress, body.count > 0 {
                            copy.withUnsafeMutableBufferPointer { destination in
                                guard let writePointer = destination.baseAddress else { return }
                                writePointer.update(
                                    from: source.assumingMemoryBound(to: UInt8.self),
                                    count: body.count
                                )
                            }
                        }
                        continuation.yield(copy)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func close() async {
        let transport = self.transport
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            worker.async {
                transport.connection.close()
                continuation.resume()
            }
        }
    }
}

// Holds the sync transport behind a final-class box that the worker
// queue can address without crossing actor isolation. The actor still
// owns the box and the worker queue, so external concurrent access is
// gated by actor isolation; the box is only read from inside async
// methods that have already entered the actor or from the worker
// itself.
final class TransportBox: @unchecked Sendable {

    let connection: ClickHouseConnection

    init(connection: ClickHouseConnection) {
        self.connection = connection
    }
}

