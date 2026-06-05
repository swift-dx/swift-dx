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
        reconnectionPolicy: ReconnectionPolicy = .alwaysRetry
    ) async throws(ClickHouseError) {
        let worker = DispatchQueue(label: "swift-dx.async-raw-clickhouse", qos: .userInitiated)
        self.worker = worker
        let box: TransportBox
        do {
            box = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TransportBox, Error>) in
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
                        continuation.resume(returning: TransportBox(connection: made))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch let typed as ClickHouseError {
            throw typed
        } catch {
            throw ClickHouseError.protocolError(stage: "async-bridge", message: String(describing: error))
        }
        self.transport = box
    }

    public func sendQuery(_ sql: String) async throws(ClickHouseError) {
        let transport = self.transport
        let _: Void = try await Self.bridgeThrowing(transport: transport) { (continuation: CheckedContinuation<Void, Error>) in
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
    ) async throws(ClickHouseError) {
        let transport = self.transport
        let _: Void = try await Self.bridgeThrowing(transport: transport) { (continuation: CheckedContinuation<Void, Error>) in
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

    // Round-trip Ping → Pong with the connection's reconnect policy
    // applied to a transient send failure.
    public func ping() async throws(ClickHouseError) {
        let transport = self.transport
        let _: Void = try await Self.bridgeThrowing(transport: transport) { (continuation: CheckedContinuation<Void, Error>) in
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

    // Single-shot Ping → Pong with NO reconnect, used by pool preflight so
    // a dead idle connection fails fast and is discarded rather than
    // looping inside reconnect under the always-retry policy.
    public func pingOnce() async throws(ClickHouseError) {
        let transport = self.transport
        let _: Void = try await Self.bridgeThrowing(transport: transport) { (continuation: CheckedContinuation<Void, Error>) in
            worker.async {
                do {
                    try transport.connection.pingOnce()
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
    public func drainBlocks() async throws(ClickHouseError) -> Int {
        let transport = self.transport
        return try await Self.bridgeThrowing(transport: transport) { (continuation: CheckedContinuation<Int, Error>) in
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
    ) async throws(ClickHouseError) -> Int {
        let transport = self.transport
        return try await Self.bridgeThrowing(transport: transport) { (continuation: CheckedContinuation<Int, Error>) in
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
    public func receiveScalarUInt64() async throws(ClickHouseError) -> UInt64 {
        let transport = self.transport
        return try await Self.bridgeThrowing(transport: transport) { (continuation: CheckedContinuation<UInt64, Error>) in
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
    public func extractStringsDrain() async throws(ClickHouseError) -> (rows: Int, bytes: Int) {
        let transport = self.transport
        return try await Self.bridgeThrowing(transport: transport) { (continuation: CheckedContinuation<(Int, Int), Error>) in
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

    // Typed collecting read on a leased pooled connection: sends the query,
    // drains every result block, and decodes each row through Codable in a
    // single worker hop, so the lease holds the connection for the query's
    // whole lifetime. This gives the pooled concurrency path the same typed
    // Codable surface the single-connection client has, instead of forcing
    // pooled callers to drop down to the raw drain/extract wire methods.
    public func selectAll<T: Decodable & Sendable>(
        _ sql: String,
        as type: T.Type,
        settings: ClickHouseQuerySettings = .empty,
        parameters: ClickHouseQueryParameters = .empty
    ) async throws(ClickHouseError) -> [T] {
        let transport = self.transport
        return try await Self.bridgeThrowing(transport: transport) { (continuation: CheckedContinuation<[T], Error>) in
            worker.async {
                do {
                    try transport.connection.sendQuery(sql, queryID: "", settings: settings, parameters: parameters)
                    var rows: [T] = []
                    var outcome = StreamDecodeOutcome.ok
                    _ = try transport.connection.receiveBlocks { block, body in
                        if block.rowCount == 0 { return }
                        if case .failed = outcome { return }
                        do {
                            let typed = try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: body)
                            rows.append(contentsOf: try ClickHouseCodableDecoder.decodeRows(type: T.self, columns: typed, rowCount: block.rowCount))
                        } catch let error as ClickHouseError {
                            outcome = .failed(error)
                        } catch {
                            outcome = .failed(.protocolError(stage: "pool.selectAll", message: "\(error)"))
                        }
                    }
                    if case .failed(let error) = outcome {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume(returning: rows)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // Bridges the untyped-throws `withCheckedThrowingContinuation` API
    // into a typed `throws(ClickHouseError)` surface. Every continuation
    // resume in this file forwards a `ClickHouseError` thrown by the
    // synchronous transport; the cast cannot fail. Should it ever fail
    // (a non-ClickHouse error escaping the transport), the catch arm
    // wraps it as a typed protocolError so the SemVer contract holds.
    @inline(__always)
    private static func bridgeThrowing<T: Sendable>(
        transport: TransportBox,
        _ body: @Sendable (CheckedContinuation<T, Error>) -> Void
    ) async throws(ClickHouseError) -> T {
        do {
            // The worker runs the body's blocking recv/send on a serial
            // queue, so a cancelled caller would otherwise stay parked until
            // the server eventually replies — and never if it has stalled.
            // Shutting the socket down from the cancellation handler unblocks
            // the parked syscall so this await fails fast instead of hanging.
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation(body)
            } onCancel: {
                transport.connection.shutdownSocketForTimeout()
            }
        } catch let typed as ClickHouseError {
            throw typed
        } catch {
            throw ClickHouseError.protocolError(stage: "async-bridge", message: String(describing: error))
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
            // A cancelled consumer would otherwise leave the worker parked in
            // a blocking recv (a stalled server never sends EndOfStream),
            // hanging every later operation behind the serial worker queue —
            // including close(). Shutting the socket down from the
            // cancellation thread unblocks that recv so the worker fails fast.
            continuation.onTermination = { reason in
                if case .cancelled = reason {
                    transport.connection.shutdownSocketForTimeout()
                }
            }
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

    deinit {
        // A connection dropped without an explicit close() — including a pooled
        // connection the pool discards — must not leak its worker thread if that
        // worker is spinning in the unbounded reconnect backoff against a gone
        // server. requestShutdown only stores an atomic (safe from a nonisolated
        // deinit, does not touch the socket), which the reconnect loop re-checks
        // each iteration and breaks on.
        transport.connection.requestShutdown()
    }

    public func close() async {
        let transport = self.transport
        // Signal shutdown BEFORE hopping onto the worker: if the worker is
        // spinning in the reconnect backoff loop, a requestShutdown enqueued
        // behind it would never run and close() would hang. Storing the atomic
        // here breaks that loop so the queued socket teardown can proceed.
        transport.connection.requestShutdown()
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
