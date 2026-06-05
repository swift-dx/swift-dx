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

// Pull-based, backpressured state machine behind the streaming select.
//
// The previous implementation pushed every decoded row into an unbounded
// AsyncThrowingStream continuation as fast as the server delivered blocks, so a
// consumer slower than the network accumulated the whole result in memory —
// streaming gave the same (or worse) memory profile as a full materialisation.
// This reads exactly one result block from the connection each time its row
// buffer drains, so memory stays bounded to a single block regardless of how
// slowly the consumer iterates: the server is only read when the consumer pulls.
//
// @unchecked Sendable: every stored property is read and written only inside
// `next()`, which AsyncThrowingStream's unfolding initializer invokes serially
// (one call completes before the next begins, never concurrently). The worker
// queue reads the connection and hands rows back through a continuation without
// touching this object's state, so there is no shared mutable access to guard.
final class ClickHouseSelectStreamState<Row: Sendable>: @unchecked Sendable {

    // The result of advancing the stream by one row: a row, or the end of the
    // result. Named rather than an optional so `next()` returns a non-optional
    // value and the AsyncThrowingStream unfolding closure maps it to the
    // standard-library end-of-sequence signal at the single call site.
    enum Step {

        case row(Row)
        case end
    }

    // The result of reading the connection forward one result block. A decode
    // failure is reported separately from a transport failure: the block was a
    // clean read, so the connection is drained to EndOfStream and stays usable —
    // the error surfaces to the consumer but the connection is NOT torn down,
    // matching the non-streaming collect paths. A transport-level broken read
    // instead throws out of the worker body and closes the connection.
    private enum BlockOutcome {

        case rows([Row])
        case end
        case decodeFailed(ClickHouseError)
    }

    private let worker: DispatchQueue
    private let transport: ClientTransportBox
    private let sql: String
    private let settings: ClickHouseQuerySettings
    private let parameters: ClickHouseQueryParameters
    private let decode: @Sendable (ClickHouseBlock, UnsafeRawBufferPointer) throws -> [Row]

    private var started = false
    private var finished = false
    private var heldQueryFlag = false
    private var buffer: [Row] = []
    private var index = 0

    init(
        worker: DispatchQueue,
        transport: ClientTransportBox,
        sql: String,
        settings: ClickHouseQuerySettings,
        parameters: ClickHouseQueryParameters,
        decode: @escaping @Sendable (ClickHouseBlock, UnsafeRawBufferPointer) throws -> [Row]
    ) {
        self.worker = worker
        self.transport = transport
        self.sql = sql
        self.settings = settings
        self.parameters = parameters
        self.decode = decode
    }

    deinit {
        if finished { return }
        // The consumer dropped the stream before EndOfStream, leaving the result's
        // remaining blocks unread on the wire. Close the connection on the worker
        // queue so the next operation reconnects to a clean socket instead of
        // reading the abandoned result's stale bytes and desyncing. Release the
        // single-flight flag in the same hop if this stream still held it, so a
        // later query is not wrongly rejected as concurrent.
        let transport = self.transport
        let held = self.heldQueryFlag
        worker.async {
            if held { transport.queryActive = false }
            transport.connection.close()
        }
    }

    func next() async throws -> Step {
        if index < buffer.count {
            let row = buffer[index]
            index += 1
            return .row(row)
        }
        if finished {
            return .end
        }
        return try await loadNextBlock()
    }

    private func loadNextBlock() async throws -> Step {
        let outcome = try await readNextBlock()
        if case .rows(let rows) = outcome {
            buffer = rows
            index = 1
            return .row(rows[0])
        }
        // Both .end and .decodeFailed reach EndOfStream, so the connection is
        // synced and reusable: mark finished so deinit does not also close it.
        // A decode failure additionally surfaces its error to the consumer.
        finished = true
        if case .decodeFailed(let error) = outcome {
            throw error
        }
        return .end
    }

    // Bridges a single-block read onto the worker queue. Returns the decoded rows
    // of the next non-empty result block, or an empty array at EndOfStream (the
    // leading header block and any intervening empty blocks are skipped). A
    // cancellation of the consuming task shuts the socket down so a worker parked
    // in a blocking recv against a stalled server unblocks immediately.
    private func readNextBlock() async throws -> BlockOutcome {
        let worker = self.worker
        let transport = self.transport
        let sql = self.sql
        let settings = self.settings
        let parameters = self.parameters
        let decode = self.decode
        let isFirst = !started
        started = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BlockOutcome, Error>) in
                worker.async {
                    if isFirst {
                        if transport.queryActive {
                            // Another result stream already holds this single
                            // connection mid-result. This stream never owned it,
                            // so mark finished: deinit must not close the
                            // connection the other stream is still reading.
                            self.finished = true
                            continuation.resume(throwing: ClickHouseError.protocolError(
                                stage: "client.concurrentQuery",
                                message: "another query's result stream is already in flight on this connection; finish or drop it before starting another query on the same client, or use one client per concurrent stream. The collecting selectAll and query are safe to call concurrently."
                            ))
                            return
                        }
                        transport.queryActive = true
                        self.heldQueryFlag = true
                    }
                    do {
                        let outcome = try transport.connection.closingOnBrokenRead { () throws(ClickHouseError) -> BlockOutcome in
                            if isFirst {
                                try transport.connection.sendQuery(
                                    sql,
                                    queryID: "",
                                    settings: settings,
                                    parameters: parameters
                                )
                            }
                            // A decode failure does not break the wire framing —
                            // the block read cleanly. Capture it and keep draining
                            // the rest of the result to EndOfStream so the
                            // connection stays synced, then report it as a value so
                            // closingOnBrokenRead does not close the connection.
                            var decodeError: [ClickHouseError] = []
                            while true {
                                var decoded: [Row] = []
                                let step = try transport.connection.readNextDataBlock { block, body in
                                    if decodeError.isEmpty {
                                        do {
                                            decoded = try decode(block, body)
                                        } catch let error as ClickHouseError {
                                            decodeError.append(error)
                                        } catch {
                                            decodeError.append(.protocolError(stage: "select.decode", message: "\(error)"))
                                        }
                                    }
                                }
                                switch step {
                                case .block:
                                    if decodeError.isEmpty && !decoded.isEmpty { return .rows(decoded) }
                                case .endOfStream:
                                    if decodeError.isEmpty { return .end }
                                    return .decodeFailed(decodeError[0])
                                }
                            }
                        }
                        // The query is complete at EndOfStream (or a decode
                        // failure that still drained the wire); release the single
                        // connection so the next query can run. A `.rows` outcome
                        // means more blocks follow, so the stream keeps the hold.
                        switch outcome {
                        case .rows: break
                        case .end, .decodeFailed:
                            transport.queryActive = false
                            self.heldQueryFlag = false
                        }
                        continuation.resume(returning: outcome)
                    } catch let error as ClickHouseError {
                        if self.heldQueryFlag { transport.queryActive = false; self.heldQueryFlag = false }
                        continuation.resume(throwing: error)
                    } catch {
                        if self.heldQueryFlag { transport.queryActive = false; self.heldQueryFlag = false }
                        continuation.resume(throwing: ClickHouseError.protocolError(stage: "select.stream", message: "\(error)"))
                    }
                }
            }
        } onCancel: {
            transport.connection.shutdownSocketForTimeout()
        }
    }
}
