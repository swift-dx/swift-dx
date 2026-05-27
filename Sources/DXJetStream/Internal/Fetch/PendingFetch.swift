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

final class PendingFetch: Sendable {

    let batch: Int
    let needsPayload: Bool

    private let state: NIOLockedValueBox<State>

    typealias FetchResult = (replies: [[UInt8]], payloads: [[UInt8]])

    private struct State {

        var replies: [[UInt8]]
        var payloads: [[UInt8]]
        var phase: Phase
    }

    private enum Phase {

        case open
        case parked(CheckedContinuation<FetchResult, any Error>)
        case finished(Result<FetchResult, any Error>)
    }

    private enum DeliverAction {

        case continueAccumulating
        case finishedNoWaiter
        case finalize(CheckedContinuation<FetchResult, any Error>, Result<FetchResult, any Error>)
    }

    private enum WaitAction {

        case parked
        case deliver(Result<FetchResult, any Error>)
    }

    init(batch: Int, needsPayload: Bool) {
        self.batch = batch
        self.needsPayload = needsPayload
        self.state = NIOLockedValueBox(State(replies: [], payloads: [], phase: .open))
    }

    func deliverReply(_ reply: [UInt8]) -> Bool {
        deliver(reply: reply, payload: [], hasPayload: false)
    }

    func deliverReplyAndPayload(_ reply: [UInt8], payload: [UInt8]) -> Bool {
        deliver(reply: reply, payload: payload, hasPayload: true)
    }

    private func deliver(reply: [UInt8], payload: [UInt8], hasPayload: Bool) -> Bool {
        let action: DeliverAction = state.withLockedValue { state in
            state.replies.append(reply)
            if hasPayload, needsPayload {
                state.payloads.append(payload)
            }
            guard state.replies.count >= batch else {
                return .continueAccumulating
            }
            let result: Result<FetchResult, any Error> = .success((replies: state.replies, payloads: state.payloads))
            state.replies = []
            state.payloads = []
            switch state.phase {
            case .open:
                state.phase = .finished(result)
                return .finishedNoWaiter
            case .parked(let continuation):
                state.phase = .finished(result)
                return .finalize(continuation, result)
            case .finished:
                return .continueAccumulating
            }
        }
        switch action {
        case .continueAccumulating:
            return false
        case .finishedNoWaiter:
            return true
        case .finalize(let continuation, let result):
            continuation.resume(with: result)
            return true
        }
    }

    func deliverStatus(_ status: UInt16) -> Bool {
        if status == 100 { return false }
        finalizeWithTerminalStatus(status)
        return true
    }

    private func finalizeWithTerminalStatus(_ status: UInt16) {
        if isAcceptableTerminalStatus(status) {
            finalize(.success(drain()))
        } else {
            finalize(.failure(JetStreamError.fetchStatus(code: status)))
        }
    }

    @inline(__always)
    private func isAcceptableTerminalStatus(_ status: UInt16) -> Bool {
        status == 404 || status == 408
    }

    func wait() async throws -> FetchResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<FetchResult, any Error>) in
            let action: WaitAction = state.withLockedValue { state in
                switch state.phase {
                case .finished(let result):
                    return .deliver(result)
                case .parked:
                    return .deliver(.failure(JetStreamError.protocolError(reason: "PendingFetch.wait called twice")))
                case .open:
                    state.phase = .parked(continuation)
                    return .parked
                }
            }
            if case .deliver(let result) = action {
                continuation.resume(with: result)
            }
        }
    }

    func failWith(_ error: any Error) {
        finalize(.failure(error))
    }

    func completeOnDeadline() {
        finalize(.success(drain()))
    }

    private func finalize(_ result: Result<FetchResult, any Error>) {
        let action: DeliverAction = state.withLockedValue { state in
            switch state.phase {
            case .finished:
                return .continueAccumulating
            case .open:
                state.phase = .finished(result)
                return .finishedNoWaiter
            case .parked(let continuation):
                state.phase = .finished(result)
                return .finalize(continuation, result)
            }
        }
        if case .finalize(let continuation, let result) = action {
            continuation.resume(with: result)
        }
    }

    private func drain() -> FetchResult {
        state.withLockedValue { state in
            let replies = state.replies
            let payloads = state.payloads
            state.replies = []
            state.payloads = []
            return (replies, payloads)
        }
    }
}
