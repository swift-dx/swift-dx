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

import Atomics
import NIOConcurrencyHelpers
import NIOCore

// One TCP connection to a Redis server. Owns the NIO Channel and the FIFO
// pending-reply queue that makes pipelining safe: a single call can write
// thousands of commands and await all of their replies because Redis answers
// in command order on the connection. `@unchecked Sendable` is justified the
// same way the rest of the data layer justifies it — the Channel is event-loop
// pinned, the pending queue is lock-guarded, and the closing flag and selected
// database are behind a lock and an atomic respectively.
final class RedisConnection: @unchecked Sendable {

    let channel: Channel
    let openedAt: NIODeadline
    let requestTimeout: TimeAmount
    private let pending: RedisPendingQueue
    private let closing = NIOLockedValueBox(false)
    private let database: ManagedAtomic<Int>

    init(channel: Channel, pending: RedisPendingQueue, selectedDatabase: Int, requestTimeout: TimeAmount) {
        self.channel = channel
        self.openedAt = NIODeadline.now()
        self.requestTimeout = requestTimeout
        self.pending = pending
        self.database = ManagedAtomic<Int>(selectedDatabase)
    }

    var isActive: Bool {
        guard !closing.withLockedValue({ $0 }) else { return false }
        return channel.isActive
    }

    // Relaxed ordering is sufficient because the selected-database index is only
    // ever read or written by the single task that currently leases this
    // connection from the pool; the pool actor's acquire/release handoff
    // supplies the happens-before edge that publishes a markDatabase store to the
    // next leaseholder. If a non-leased reader is ever introduced, switch the
    // store to .releasing and the load to .acquiring.
    var currentDatabase: Int {
        database.load(ordering: .relaxed)
    }

    func markDatabase(_ index: Int) {
        database.store(index, ordering: .relaxed)
    }

    func send(_ command: RedisCommand) async throws -> RESPValue {
        let replies = try await sendBatch([command], mode: .collect)
        return try Self.firstReply(replies)
    }

    func pipeline(_ commands: [RedisCommand]) async throws -> [RESPValue] {
        try await sendBatch(commands, mode: .collect)
    }

    func pipelineExpectingSuccess(_ commands: [RedisCommand]) async throws {
        _ = try await sendBatch(commands, mode: .successOnly)
    }

    func writeEncoded(_ buffer: ByteBuffer, expecting replyCount: Int, mode: RedisPendingQueue.DeliveryMode) async throws -> [RESPValue] {
        try await park(replyCount: replyCount, mode: mode, shape: .values, buffer: buffer)
    }

    func sendArray(_ command: RedisCommand) async throws -> RedisReplyArray {
        let arrays = try await sendArrayBatch([command])
        guard let first = arrays.first else { throw RedisError.incompleteResponse }
        return first
    }

    func sendArrayBatch(_ commands: [RedisCommand]) async throws -> [RedisReplyArray] {
        guard !commands.isEmpty else { throw RedisError.emptyCommandBatch }
        try Self.validateNonEmpty(commands)
        let buffer = RESPBatchWriter.encodeCommands(commands, allocator: channel.allocator)
        let replies = try await park(replyCount: commands.count, mode: .collect, shape: .arrays, buffer: buffer)
        return try Self.arrayReplies(replies)
    }

    private static func arrayReplies(_ replies: [RESPValue]) throws -> [RedisReplyArray] {
        var result = [RedisReplyArray]()
        result.reserveCapacity(replies.count)
        for reply in replies {
            guard case .arrayReply(let array) = try reply.throwingServerError() else {
                throw RedisError.unexpectedResponseType(expected: "array", actual: reply.kindName)
            }
            result.append(array)
        }
        return result
    }

    // Switches the connection to a logical database as its own round trip. The
    // selected-database index is only updated after the server acknowledges the
    // SELECT with +OK, so a later failure on the connection can never leave the
    // tracked index out of step with the connection's real state.
    func selectDatabase(_ index: Int) async throws {
        let reply = try await send(.selectDatabase(index))
        try Self.expectOK(reply) { RedisError.serverError(prefix: "SELECT", message: $0) }
        markDatabase(index)
    }

    func pipelineSet(_ pairs: [RedisKeyValuePair]) async throws {
        guard !pairs.isEmpty else { return }
        let buffer = RESPBatchWriter.encodeSetBatch(pairs, allocator: channel.allocator)
        _ = try await park(replyCount: pairs.count, mode: .successOnly, shape: .values, buffer: buffer)
    }

    func multiSet(_ pairs: [RedisKeyValuePair]) async throws {
        guard !pairs.isEmpty else { return }
        let buffer = RESPBatchWriter.encodeMultiSet(pairs, allocator: channel.allocator)
        _ = try await park(replyCount: 1, mode: .successOnly, shape: .values, buffer: buffer)
    }

    func pipelineGet(_ keys: [RedisKey]) async throws -> [RESPValue] {
        guard !keys.isEmpty else { return [] }
        let buffer = RESPBatchWriter.encodeGetBatch(keys, allocator: channel.allocator)
        return try await park(replyCount: keys.count, mode: .collect, shape: .values, buffer: buffer)
    }

    private func sendBatch(_ commands: [RedisCommand], mode: RedisPendingQueue.DeliveryMode) async throws -> [RESPValue] {
        guard !commands.isEmpty else { throw RedisError.emptyCommandBatch }
        try Self.validateNonEmpty(commands)
        let buffer = RESPBatchWriter.encodeCommands(commands, allocator: channel.allocator)
        return try await park(replyCount: commands.count, mode: mode, shape: .values, buffer: buffer)
    }

    private static func validateNonEmpty(_ commands: [RedisCommand]) throws {
        for command in commands {
            guard !command.arguments.isEmpty else { throw RedisError.emptyCommand }
        }
    }

    // The command's bytes are already on the wire once submit runs, and the
    // reply must still be consumed to keep the FIFO correlation intact for the
    // next waiter. A cancelled or timed-out wait therefore closes the connection
    // rather than abandoning the head of the queue: channelInactive then drives
    // failAll, which resumes this (and any other parked) continuation with
    // connectionClosed, and the closed connection is not returned to the pool. A
    // timeout closes the connection the same way but reports timedOut to its own
    // caller, distinguished by the per-wait flag the event-loop timer sets.
    private func park(replyCount: Int, mode: RedisPendingQueue.DeliveryMode, shape: RedisPendingQueue.ResponseShape, buffer: ByteBuffer) async throws -> [RESPValue] {
        let timedOut = ManagedAtomic<Bool>(false)
        let timeout = scheduleTimeout(timedOut)
        do {
            let replies = try await awaitReplies(replyCount: replyCount, mode: mode, shape: shape, buffer: buffer)
            timeout.cancel()
            return replies
        } catch {
            timeout.cancel()
            if timedOut.load(ordering: .relaxed) { throw RedisError.timedOut }
            throw error
        }
    }

    private func scheduleTimeout(_ timedOut: ManagedAtomic<Bool>) -> Scheduled<Void> {
        channel.eventLoop.scheduleTask(in: requestTimeout) {
            timedOut.store(true, ordering: .relaxed)
            self.closeImmediately()
        }
    }

    private func awaitReplies(replyCount: Int, mode: RedisPendingQueue.DeliveryMode, shape: RedisPendingQueue.ResponseShape, buffer: ByteBuffer) async throws -> [RESPValue] {
        try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation { continuation in
                pending.submit(expecting: replyCount, mode: mode, shape: shape, continuation: continuation) {
                    channel.writeAndFlush(buffer, promise: nil)
                }
            }
        } onCancel: {
            closeImmediately()
        }
    }

    private func closeImmediately() {
        closing.withLockedValue { $0 = true }
        channel.close(promise: nil)
    }

    private static func firstReply(_ replies: [RESPValue]) throws -> RESPValue {
        guard let first = replies.first else { throw RedisError.incompleteResponse }
        return first
    }

    func close() async {
        closing.withLockedValue { $0 = true }
        try? await channel.close().get()
    }
}
