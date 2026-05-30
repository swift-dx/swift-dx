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
import NIOCore

extension ClickHouseConnection {

    // Construct a Query packet with the compression flag derived from
    // this connection's negotiated mode. The flag tells the server to
    // compress Data packet bodies (for SELECT responses); it must
    // match the connection's actual codec setting otherwise the wire
    // bytes are mis-framed.
    private func makeQueryPacket(
        queryID: String,
        queryText: String,
        settings: [ClickHouseQuerySetting],
        parameters: [ClickHouseQueryParameter]
    ) -> ClickHouseQueryPacket {
        // ClientInfo.client_tcp_protocol_version travels inside the Query
        // packet as the client's self-reported protocol version. CH server
        // reads it for distributed-query forwarding and metadata logging.
        // It MUST match what the client advertised in the Hello packet,
        // otherwise we send the server two contradictory revisions for
        // the same logical "client TCP protocol version" — an entropy
        // gap that survived because both sides have independent defaults.
        // Source of truth is the negotiated handshake's clientHello.
        var clientInfo = ClickHouseClientInfo()
        clientInfo.clientRevision = metadata.clientHello.protocolRevision
        return ClickHouseQueryPacket(
            queryID: queryID,
            clientInfo: clientInfo,
            settings: settings,
            compression: compression != .uncompressed,
            queryText: queryText,
            parameters: parameters
        )
    }

    // No-op progress callback used as the default when callers don't
    // want progress notifications. Sharing one instance avoids a
    // per-call closure allocation on the hot path; the closure body is
    // empty so the optimiser can elide the call entirely at the
    // progress-emit site under whole-module optimisation.
    static let noProgressCallback: @Sendable (ClickHouseProgress) -> Void = { _ in }

    // Fire-and-forget execution: send a query, send the empty input
    // terminator, drain response packets until EndOfStream (or throw on
    // Exception). Used for DDL (CREATE/DROP/ALTER), TRUNCATE, and
    // server-side data movement queries (INSERT...SELECT) where no
    // blocks cross the client. Any data blocks the server emits are
    // ignored — callers that want the rows should use `selectBlocks`.
    func execute(
        _ queryText: String,
        settings: [ClickHouseQuerySetting] = [],
        parameters: [ClickHouseQueryParameter] = [],
        queryID: String = "",
        onProgress: @escaping @Sendable (ClickHouseProgress) -> Void = noProgressCallback
    ) async throws {
        do {
            try await runWithCancellationGuard { _ in
                try await self.runExecute(
                    queryText: queryText,
                    settings: settings,
                    parameters: parameters,
                    queryID: queryID,
                    onProgress: onProgress
                )
            }
        } catch {
            // Any throw during the wire phase (server exception, task
            // cancellation, network/decode error) leaves the connection in
            // an indeterminate mid-query state. Tear it down so the pool
            // discards it on release rather than handing a confused
            // connection to the next caller.
            try? await close()
            throw error
        }
    }

    private func runExecute(
        queryText: String,
        settings: [ClickHouseQuerySetting],
        parameters: [ClickHouseQueryParameter],
        queryID: String,
        onProgress: @escaping @Sendable (ClickHouseProgress) -> Void
    ) async throws {
        let resolvedQueryID = queryID.isEmpty ? UUID().uuidString : queryID
        let query = makeQueryPacket(
            queryID: resolvedQueryID,
            queryText: queryText,
            settings: settings,
            parameters: parameters
        )
        let emptyBlock = ClickHouseBlock(blockInfo: .init(), columns: [])
        let lifecycle = ClickHouseQueryLifecycle(revision: metadata.negotiatedRevision)

        try await send(.query(query))
        try await send(.data(tableName: "", block: emptyBlock))

        try await drainExecuteResponse(lifecycle: lifecycle, onProgress: onProgress)
    }

    private func drainExecuteResponse(
        lifecycle: ClickHouseQueryLifecycle,
        onProgress: @escaping @Sendable (ClickHouseProgress) -> Void
    ) async throws {
        while true {
            let packet: ClickHouseServerPacket
            switch try await nextPacket() {
            case .packet(let p): packet = p
            case .streamEnded: throw ClickHouseError.unexpectedConnectionClose
            }
            let event = try lifecycle.handle(packet)
            switch event {
            case .completed:
                return
            case .failed(let exception):
                throw ClickHouseError.serverException(exception.toPublic())
            case .progress(let progress):
                onProgress(progress.publicProgress)
            default:
                continue
            }
        }
    }

    func insertBlocks(
        _ queryText: String,
        blocks: [ClickHouseBlock],
        settings: [ClickHouseQuerySetting] = [],
        parameters: [ClickHouseQueryParameter] = [],
        queryID: String = "",
        onProgress: @escaping @Sendable (ClickHouseProgress) -> Void = noProgressCallback
    ) async throws {
        let cursor = ClickHouseBlockArrayCursor(blocks: blocks)
        try await insertBlockStream(
            queryText,
            nextBlock: { cursor.next() },
            settings: settings,
            parameters: parameters,
            queryID: queryID,
            onProgress: onProgress
        )
    }

    func insertBlockStream(
        _ queryText: String,
        nextBlock: @Sendable () async throws -> ClickHouseBlockCursorOutcome,
        settings: [ClickHouseQuerySetting] = [],
        parameters: [ClickHouseQueryParameter] = [],
        queryID: String = "",
        onProgress: @escaping @Sendable (ClickHouseProgress) -> Void = noProgressCallback
    ) async throws {
        // Wire-phase failures during the INSERT lifecycle (server
        // Exception in readyLoop, server hangup before EndOfStream,
        // decode failures) must close the channel before the error
        // propagates. Otherwise the pool's `release()` would park a
        // mid-INSERT connection in idle with stale inbound bytes
        // (post-Exception EndOfStream, etc.), and the next caller's
        // first packet read would consume those bytes as their own
        // query response — silent cross-query response mismatch.
        // Symmetric with `execute(...)` and `runSelectStream(...)`,
        // both of which already close on any catch path. The inner
        // catch in runInsertBlockStream's data-sending phase remains
        // defensive but is now redundant; keeping it harmless since
        // a second `close()` on an already-closed channel is a typed
        // no-op via `ChannelError.alreadyClosed`.
        do {
            try await runWithCancellationGuard { _ in
                try await self.runInsertBlockStream(
                    queryText,
                    nextBlock: nextBlock,
                    settings: settings,
                    parameters: parameters,
                    queryID: queryID,
                    onProgress: onProgress
                )
            }
        } catch {
            try? await close()
            throw error
        }
    }

    private func runInsertBlockStream(
        _ queryText: String,
        nextBlock: @Sendable () async throws -> ClickHouseBlockCursorOutcome,
        settings: [ClickHouseQuerySetting],
        parameters: [ClickHouseQueryParameter],
        queryID: String,
        onProgress: @escaping @Sendable (ClickHouseProgress) -> Void
    ) async throws {
        let resolvedQueryID = queryID.isEmpty ? UUID().uuidString : queryID
        let query = makeQueryPacket(
            queryID: resolvedQueryID,
            queryText: queryText,
            settings: settings,
            parameters: parameters
        )
        let emptyBlock = ClickHouseBlock(blockInfo: .init(), columns: [])
        let lifecycle = ClickHouseQueryLifecycle(revision: metadata.negotiatedRevision)

        try await send(.query(query))
        try await send(.data(tableName: "", block: emptyBlock))

        let schema = try await awaitInsertSchemaBlock(lifecycle: lifecycle, onProgress: onProgress)
        try await sendInsertBlocks(schema: schema, nextBlock: nextBlock, emptyBlock: emptyBlock)
        try await awaitInsertCompletion(lifecycle: lifecycle, onProgress: onProgress)
    }

    private enum InsertSchemaEventOutcome {
        case ready(ClickHouseBlock)
        case completed
        case keepWaiting
    }

    private func awaitInsertSchemaBlock(
        lifecycle: ClickHouseQueryLifecycle,
        onProgress: @escaping @Sendable (ClickHouseProgress) -> Void
    ) async throws -> ClickHouseBlock {
        while true {
            let packet = try await requirePacket()
            let event = try lifecycle.handle(packet)
            switch try handleInsertSchemaEvent(event, onProgress: onProgress) {
            case .ready(let block): return block
            case .completed: throw ClickHouseError.insertSampleBlockMissing
            case .keepWaiting: continue
            }
        }
    }

    private func handleInsertSchemaEvent(
        _ event: ClickHouseQueryLifecycle.Event,
        onProgress: @escaping @Sendable (ClickHouseProgress) -> Void
    ) throws -> InsertSchemaEventOutcome {
        switch event {
        case .data(let block) where block.rowCount == 0: return .ready(block)
        case .failed(let exception): throw ClickHouseError.serverException(exception.toPublic())
        case .completed: return .completed
        case .progress(let progress): onProgress(progress.publicProgress); return .keepWaiting
        default: return .keepWaiting
        }
    }

    private func sendInsertBlocks(
        schema: ClickHouseBlock,
        nextBlock: @Sendable () async throws -> ClickHouseBlockCursorOutcome,
        emptyBlock: ClickHouseBlock
    ) async throws {
        do {
            loop: while true {
                switch try await nextBlock() {
                case .block(let block):
                    try await sendPromotedBlock(block, schema: schema)
                case .endOfStream:
                    break loop
                }
            }
            try await send(.data(tableName: "", block: emptyBlock))
        } catch {
            try? await close()
            throw error
        }
    }

    private func sendPromotedBlock(_ block: ClickHouseBlock, schema: ClickHouseBlock) async throws {
        let promoted = try ClickHouseInsertColumnPromoter.promote(block: block, toMatch: schema)
        try await send(.data(tableName: "", block: promoted))
    }

    private func awaitInsertCompletion(
        lifecycle: ClickHouseQueryLifecycle,
        onProgress: @escaping @Sendable (ClickHouseProgress) -> Void
    ) async throws {
        while true {
            let packet = try await requirePacket()
            let event = try lifecycle.handle(packet)
            if try handleInsertCompletionEvent(event, onProgress: onProgress) {
                return
            }
        }
    }

    private func handleInsertCompletionEvent(
        _ event: ClickHouseQueryLifecycle.Event,
        onProgress: @escaping @Sendable (ClickHouseProgress) -> Void
    ) throws -> Bool {
        switch event {
        case .completed:
            return true
        case .failed(let exception):
            throw ClickHouseError.serverException(exception.toPublic())
        case .progress(let progress):
            onProgress(progress.publicProgress)
            return false
        default:
            return false
        }
    }

    private func requirePacket() async throws -> ClickHouseServerPacket {
        switch try await nextPacket() {
        case .packet(let packet): return packet
        case .streamEnded: throw ClickHouseError.unexpectedConnectionClose
        }
    }

    func selectBlocks(
        _ queryText: String,
        settings: [ClickHouseQuerySetting] = [],
        parameters: [ClickHouseQueryParameter] = [],
        queryID: String = "",
        onProgress: @escaping @Sendable (ClickHouseProgress) -> Void = noProgressCallback
    ) -> AsyncThrowingStream<ClickHouseBlock, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.runSelectStream(
                    queryText: queryText,
                    settings: settings,
                    parameters: parameters,
                    queryID: queryID,
                    continuation: continuation,
                    onProgress: onProgress
                )
            }
            // Cancel the inner task when the public stream's consumer
            // abandons it (break, throw, surrounding Task cancelled).
            // The cancellation handler in runWithCancellationGuard
            // distinguishes mid-flight cancellation from after-the-fact
            // termination via a completion flag, so a normal
            // end-of-stream that fires this onTermination after the
            // work has marked itself complete won't close the channel.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runSelectStream(
        queryText: String,
        settings: [ClickHouseQuerySetting],
        parameters: [ClickHouseQueryParameter],
        queryID: String,
        continuation: AsyncThrowingStream<ClickHouseBlock, Error>.Continuation,
        onProgress: @escaping @Sendable (ClickHouseProgress) -> Void
    ) async {
        do {
            try await runWithCancellationGuard { completed in
                try await self.sendSelectHeader(
                    queryText: queryText,
                    settings: settings,
                    parameters: parameters,
                    queryID: queryID
                )
                try await self.streamUntilTerminated(
                    continuation: continuation,
                    onProgress: onProgress,
                    completed: completed
                )
            }
        } catch {
            // Any wire-phase error (server exception, unexpected close,
            // decode failure) tears the connection down so the pool
            // discards it on release. Matches insertBlocks/execute.
            try? await close()
            continuation.finish(throwing: error)
        }
    }

    private func sendSelectHeader(
        queryText: String,
        settings: [ClickHouseQuerySetting],
        parameters: [ClickHouseQueryParameter],
        queryID: String
    ) async throws {
        let resolvedQueryID = queryID.isEmpty ? UUID().uuidString : queryID
        let query = makeQueryPacket(
            queryID: resolvedQueryID,
            queryText: queryText,
            settings: settings,
            parameters: parameters
        )
        try await send(.query(query))
        let emptyBlock = ClickHouseBlock(blockInfo: .init(), columns: [])
        try await send(.data(tableName: "", block: emptyBlock))
    }

    // Wraps a query body so Task.cancel terminates the in-flight wire
    // exchange instead of hanging on `await iterator.next()`. The
    // cancellation handler closes the channel; NIO fires
    // `channelInactive`, which finishes the inbound packets stream;
    // the pending `iterator.next()` returns `nil`; the loop exits via
    // `unexpectedConnectionClose` and the caller's outer catch closes
    // the (already-closed) connection so the pool discards it.
    //
    // The handler is fire-and-forget by design: `withTaskCancellationHandler`'s
    // `onCancel` is non-async, so we dispatch the close into a Task.
    // Doubled `close()` calls are idempotent on `ChannelError.alreadyClosed`.
    private func runWithCancellationGuard<T: Sendable>(
        _ body: @Sendable (ManagedAtomicCompletion) async throws -> T
    ) async throws -> T {
        // The body receives the completion flag and marks it BEFORE
        // any signal that could cause the consumer to terminate the
        // public stream (specifically `continuation.finish()` in the
        // streaming path). That ordering is what makes the cancel
        // handler safe: by the time the onTermination cascade reaches
        // this Task, the flag is already `completed` and the close
        // is suppressed. A genuine mid-flight cancel arrives while
        // the flag is still `pending`, the handler trips it to
        // `cancelled`, and `closeNonBlocking()` runs.
        let completed = ManagedAtomicCompletion()
        do {
            let result = try await withTaskCancellationHandler {
                try await body(completed)
            } onCancel: { [self] in
                // Race between completed and onCancel: if the body
                // already marked itself complete (the soft-abandon
                // path or normal end-of-stream did so before the
                // onTermination cascade), skip the hard close — the
                // connection is being released cleanly. Otherwise the
                // body is suspended on `await nextPacket()` and the
                // only way to unblock it is to close the channel,
                // which fires `channelInactive` and finishes the
                // inbound stream so `nextPacket()` returns nil.
                if completed.markAndCheckPending() {
                    closeNonBlocking()
                }
            }
            completed.markCompleted()
            return result
        } catch {
            completed.markCompleted()
            throw error
        }
    }

    // Consumer-abandonment drain. When the user stops iterating early, the
    // next `continuation.yield(...)` returns `.terminated`. We send a
    // Cancel packet, flip into drain mode, and keep reading until the
    // server confirms with EndOfStream — leaving the connection in a
    // clean state so the pool can safely reuse it for the next query.
    //
    // If the inbound stream ends without a terminal lifecycle event
    // (server hangup mid-query), throw `unexpectedConnectionClose` so
    // the consumer can distinguish that from a legitimate zero-row
    // completion. Same pattern as `insertBlocks` and `execute`.
    private func streamUntilTerminated(
        continuation: AsyncThrowingStream<ClickHouseBlock, Error>.Continuation,
        onProgress: @escaping @Sendable (ClickHouseProgress) -> Void,
        completed: ManagedAtomicCompletion
    ) async throws {
        let lifecycle = ClickHouseQueryLifecycle(revision: metadata.negotiatedRevision)
        var draining = false
        while true {
            let packet = try await requirePacket()
            let event = try lifecycle.handle(packet)
            if try handleSelectStreamEvent(event, draining: &draining, continuation: continuation, onProgress: onProgress, completed: completed) {
                return
            }
        }
    }

    private func handleSelectStreamEvent(
        _ event: ClickHouseQueryLifecycle.Event,
        draining: inout Bool,
        continuation: AsyncThrowingStream<ClickHouseBlock, Error>.Continuation,
        onProgress: @escaping @Sendable (ClickHouseProgress) -> Void,
        completed: ManagedAtomicCompletion
    ) throws -> Bool {
        switch event {
        case .data(let block): return handleSelectDataEvent(block: block, draining: &draining, continuation: continuation)
        case .completed: return finishSelectStream(continuation: continuation, completed: completed)
        case .failed(let exception): throw ClickHouseError.serverException(exception.toPublic())
        case .progress(let progress): return reportSelectProgress(progress: progress, onProgress: onProgress)
        case .profileInfo, .totals, .extremes, .log, .profileEvents, .tableColumns, .ignored: return false
        }
    }

    private func handleSelectDataEvent(
        block: ClickHouseBlock,
        draining: inout Bool,
        continuation: AsyncThrowingStream<ClickHouseBlock, Error>.Continuation
    ) -> Bool {
        guard !draining, block.rowCount > 0 else { return false }
        yieldOrDrain(block: block, draining: &draining, continuation: continuation)
        return false
    }

    private func finishSelectStream(
        continuation: AsyncThrowingStream<ClickHouseBlock, Error>.Continuation,
        completed: ManagedAtomicCompletion
    ) -> Bool {
        completed.markCompleted()
        continuation.finish()
        return true
    }

    private func reportSelectProgress(
        progress: ClickHouseServerProgressPacket,
        onProgress: @escaping @Sendable (ClickHouseProgress) -> Void
    ) -> Bool {
        onProgress(progress.publicProgress)
        return false
    }

    private func yieldOrDrain(
        block: ClickHouseBlock,
        draining: inout Bool,
        continuation: AsyncThrowingStream<ClickHouseBlock, Error>.Continuation
    ) {
        if case .terminated = continuation.yield(block) {
            draining = true
        }
    }

}
