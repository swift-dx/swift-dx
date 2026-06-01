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

// A pull-based queue of decoded backend messages bridging the NIO event loop to
// the async request code. The inbound handler pushes whole reads through
// `deliver`; the connection pulls one message at a time with `next`. The pool
// leases each connection to a single task between acquire and release, so there
// is at most one waiter at any moment — the model is deliberately single-waiter
// rather than a general broadcast. When the channel closes, `fail` records the
// cause; messages already buffered are still drained by `next` before the
// failure surfaces, after which every `next` throws the recorded error.
//
// `@unchecked Sendable` is sound because all state lives inside the lock-guarded
// box and continuations are resumed exactly once: a buffered message resumes the
// waiter, or `fail` resumes it, never both, because resuming clears the waiter
// under the same lock.
final class PostgresMessageStream: @unchecked Sendable {

    private enum Waiter {

        case none
        case waiting(UnsafeContinuation<BackendMessage, Error>)
    }

    private enum Liveness {

        case open
        case closed(PostgresError)
    }

    private struct State {

        var buffered: [BackendMessage] = []
        var readIndex = 0
        var waiter: Waiter = .none
        var liveness: Liveness = .open

        var hasBuffered: Bool {
            readIndex < buffered.count
        }

        mutating func popFront() -> BackendMessage {
            let message = buffered[readIndex]
            readIndex += 1
            if readIndex == buffered.count {
                buffered.removeAll(keepingCapacity: true)
                readIndex = 0
            }
            return message
        }
    }

    private enum NextAction {

        case deliver(UnsafeContinuation<BackendMessage, Error>, BackendMessage)
        case failWaiter(UnsafeContinuation<BackendMessage, Error>, PostgresError)
        case park

        func fire() {
            switch self {
            case .deliver(let continuation, let message): continuation.resume(returning: message)
            case .failWaiter(let continuation, let error): continuation.resume(throwing: error)
            case .park: return
            }
        }
    }

    private let state = NIOLockedValueBox(State())

    func next() async throws -> BackendMessage {
        try await withUnsafeThrowingContinuation { continuation in
            register(continuation).fire()
        }
    }

    private func register(_ continuation: UnsafeContinuation<BackendMessage, Error>) -> NextAction {
        state.withLockedValue { state in
            if state.hasBuffered {
                return .deliver(continuation, state.popFront())
            }
            if case .closed(let error) = state.liveness {
                return .failWaiter(continuation, error)
            }
            state.waiter = .waiting(continuation)
            return .park
        }
    }

    func deliver(_ messages: [BackendMessage]) {
        guard !messages.isEmpty else { return }
        wakeWaiter(after: { $0.buffered.append(contentsOf: messages) }).fire()
    }

    func fail(_ error: PostgresError) {
        let waiter = state.withLockedValue { state -> Waiter in
            if case .open = state.liveness {
                state.liveness = .closed(error)
            }
            let parked = state.waiter
            state.waiter = .none
            return parked
        }
        guard case .waiting(let continuation) = waiter else { return }
        continuation.resume(throwing: error)
    }

    private func wakeWaiter(after mutate: (inout State) -> Void) -> NextAction {
        state.withLockedValue { state in
            mutate(&state)
            guard case .waiting(let continuation) = state.waiter, state.hasBuffered else { return .park }
            state.waiter = .none
            return .deliver(continuation, state.popFront())
        }
    }
}
