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

import NIOConcurrencyHelpers

// Correlates pipelined Redis replies to the requests that produced them.
// Redis delivers replies on a single connection in the exact order the
// commands were written, so correlation is a strict FIFO: the head of the
// queue owns the next reply. A request that wrote N commands waits for N
// replies before its continuation resumes. The load-bearing ordering invariant
// is per-connection single-tenancy: the connection pool leases each connection
// to exactly one task between acquire and release, so concurrent senders on one
// connection do not occur in normal operation. submit additionally appends the
// pending entry and submits the channel write under the same lock, so even if a
// connection were ever shared the queue order would stay paired with the order
// the writes are handed to the event loop.
//
// The waiters use `UnsafeContinuation` rather than `CheckedContinuation`: every
// pending entry resumes exactly once and never zero times. accept removes the
// entry from the queue the moment its reply count reaches zero and resumes it;
// failAll drains the queue once and resumes every remaining entry; the two paths
// are mutually exclusive because a resumed entry is no longer in the queue. A
// parked request that is cancelled closes the channel, which drives
// channelInactive then failAll, so cancellation also resolves to exactly one
// resume. The checked variant's double-resume and leak detection is therefore
// redundant here, and the unsafe variant removes its per-await heap box and
// atomic state machine from the single-operation hot path.
final class RedisPendingQueue: @unchecked Sendable {

    enum DeliveryMode: Sendable {

        case collect
        case successOnly
    }

    // How the inbound handler should decode the replies for the request at the
    // head of the queue. `values` builds the recursive `RESPValue` tree;
    // `arrays` decodes each top-level array into a flat-slot `RedisReplyArray`
    // (one backing buffer plus an offsets table, no per-element allocation). The
    // pool leases a connection to one task at a time, so every reply arriving in
    // one read belongs to the head request and shares its shape; the handler
    // therefore reads the head shape once per read rather than per frame.
    enum ResponseShape: Sendable {

        case values
        case arrays
    }

    private enum ErrorSlot {

        case empty
        case captured(RedisError)
    }

    private struct Pending {

        let continuation: UnsafeContinuation<[RESPValue], Error>
        let mode: DeliveryMode
        let shape: ResponseShape
        var remaining: Int
        var collected: [RESPValue]
        var errorSlot: ErrorSlot

        var isComplete: Bool {
            remaining == 0
        }

        mutating func accept(_ value: RESPValue) {
            remaining -= 1
            switch mode {
            case .collect: collected.append(value)
            case .successOnly: captureError(value)
            }
        }

        mutating func captureError(_ value: RESPValue) {
            guard case .error(let prefix, let message) = value else { return }
            recordFirstError(.serverError(prefix: prefix, message: message))
        }

        mutating func recordFirstError(_ error: RedisError) {
            guard case .empty = errorSlot else { return }
            errorSlot = .captured(error)
        }

        func result() -> Result<[RESPValue], Error> {
            switch errorSlot {
            case .empty: .success(collected)
            case .captured(let error): .failure(error)
            }
        }
    }

    private enum Delivery {

        case ignore
        case resume(UnsafeContinuation<[RESPValue], Error>, Result<[RESPValue], Error>)

        func fire() {
            guard case .resume(let continuation, let result) = self else { return }
            continuation.resume(with: result)
        }
    }

    private struct State {

        var queue: [Pending] = []
        var isOpen = true

        func headShape() -> ResponseShape {
            guard let head = queue.first else { return .values }
            return head.shape
        }

        mutating func append(_ pending: Pending) {
            queue.append(pending)
        }

        mutating func accept(_ value: RESPValue) -> Delivery {
            guard !queue.isEmpty else { return .ignore }
            queue[0].accept(value)
            guard queue[0].isComplete else { return .ignore }
            let pending = queue.removeFirst()
            return .resume(pending.continuation, pending.result())
        }

        mutating func acceptAll(_ values: [RESPValue]) -> [Delivery] {
            var resumes: [Delivery] = []
            for value in values {
                let delivery = accept(value)
                if case .resume = delivery { resumes.append(delivery) }
            }
            return resumes
        }

        mutating func drain() -> [Pending] {
            isOpen = false
            let drained = queue
            queue.removeAll(keepingCapacity: false)
            return drained
        }
    }

    private let state = NIOLockedValueBox(State())

    func submit(expecting replyCount: Int, mode: DeliveryMode, shape: ResponseShape, continuation: UnsafeContinuation<[RESPValue], Error>, write: () -> Void) {
        let accepted = state.withLockedValue { state -> Bool in
            guard state.isOpen else { return false }
            state.append(.init(continuation: continuation, mode: mode, shape: shape, remaining: replyCount, collected: [], errorSlot: .empty))
            write()
            return true
        }
        guard !accepted else { return }
        continuation.resume(throwing: RedisError.connectionClosed)
    }

    func headShape() -> ResponseShape {
        state.withLockedValue { $0.headShape() }
    }

    func deliver(_ value: RESPValue) {
        state.withLockedValue { $0.accept(value) }.fire()
    }

    // Distributes a whole channelRead's worth of replies under a single lock and
    // fires the (rare) completions outside it. A pipelined batch of N replies
    // costs one lock acquisition here instead of N.
    func deliverBatch(_ values: [RESPValue]) {
        let resumes = state.withLockedValue { $0.acceptAll(values) }
        for delivery in resumes {
            delivery.fire()
        }
    }

    func failAll(_ error: RedisError) {
        let drained = state.withLockedValue { $0.drain() }
        for pending in drained {
            pending.continuation.resume(throwing: error)
        }
    }
}
