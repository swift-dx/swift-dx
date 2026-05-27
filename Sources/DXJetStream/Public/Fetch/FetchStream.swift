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

import DXCore
import NIOConcurrencyHelpers

public final class FetchStream: Sendable {

    let sid: UInt64
    let inbox: String
    let needsPayload: Bool
    let pubSubject: String
    private let connection: JetStreamClientImpl
    private let state: NIOLockedValueBox<State>

    public struct Result: Sendable {

        public let subjects: [[UInt8]]
        public let replies: [[UInt8]]
        public let headers: [[NatsHeader]]
        public let payloads: [[UInt8]]

        public var repliesAsStrings: [String] {
            replies.map { String(decoding: $0, as: UTF8.self) }
        }
    }

    private struct State {

        var subjects: [[UInt8]]
        var replies: [[UInt8]]
        var headers: [[NatsHeader]]
        var payloads: [[UInt8]]
        var minimumCount: Int
        var phase: Phase
    }

    private enum Phase: Sendable {

        case idle
        case parked(CheckedContinuation<Void, Never>)
        case closed
    }

    private enum WaitAction {

        case parked
        case resumeImmediately(CheckedContinuation<Void, Never>)
    }

    private enum DeliverAction {

        case continueAccumulating
        case resume(CheckedContinuation<Void, Never>)
    }

    init(sid: UInt64, inbox: String, needsPayload: Bool, pubSubject: String, connection: JetStreamClientImpl) {
        self.sid = sid
        self.inbox = inbox
        self.needsPayload = needsPayload
        self.pubSubject = pubSubject
        self.connection = connection
        var initial = State(subjects: [], replies: [], headers: [], payloads: [], minimumCount: 0, phase: .idle)
        initial.subjects.reserveCapacity(2048)
        initial.replies.reserveCapacity(2048)
        initial.headers.reserveCapacity(2048)
        if needsPayload { initial.payloads.reserveCapacity(2048) }
        self.state = NIOLockedValueBox(initial)
    }

    public func requestAndAwait(batch: Int, expires: TimeSpan, wait: FetchWait = .fill) async throws(JetStreamError) -> Result {
        let minimum = resolveMinimum(batch: batch, wait: wait)
        state.withLockedValue { $0.minimumCount = minimum }

        let frame = FrameBuilder.buildPullRequest(
            pubSubject: pubSubject,
            inbox: inbox,
            batch: batch,
            expiresNanos: expires.nanoseconds
        )
        connection.writeBytesNonBlocking(frame)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let action: WaitAction = state.withLockedValue { state in
                switch state.phase {
                case .closed:
                    return .resumeImmediately(continuation)
                case .idle:
                    if state.replies.count >= minimum {
                        return .resumeImmediately(continuation)
                    }
                    state.phase = .parked(continuation)
                    return .parked
                case .parked:
                    return .resumeImmediately(continuation)
                }
            }
            if case .resumeImmediately(let c) = action {
                c.resume()
            }
        }

        return state.withLockedValue { state in
            let take = Swift.min(batch, state.replies.count)
            let subjects = Array(state.subjects.prefix(take))
            let replies = Array(state.replies.prefix(take))
            let headers = Array(state.headers.prefix(take))
            let payloads = needsPayload ? Array(state.payloads.prefix(take)) : []
            state.subjects.removeFirst(take)
            state.replies.removeFirst(take)
            state.headers.removeFirst(take)
            if needsPayload { state.payloads.removeFirst(take) }
            state.minimumCount = 0
            return Result(subjects: subjects, replies: replies, headers: headers, payloads: payloads)
        }
    }

    func deliverReply(subject: [UInt8], reply: [UInt8], headers: [NatsHeader]) {
        let action: DeliverAction = state.withLockedValue { state in
            state.subjects.append(subject)
            state.replies.append(reply)
            state.headers.append(headers)
            return wakeUpIfReady(&state)
        }
        if case .resume(let continuation) = action {
            continuation.resume()
        }
    }

    func deliverReplyAndPayload(subject: [UInt8], reply: [UInt8], headers: [NatsHeader], payload: [UInt8]) {
        let action: DeliverAction = state.withLockedValue { state in
            state.subjects.append(subject)
            state.replies.append(reply)
            state.headers.append(headers)
            state.payloads.append(payload)
            return wakeUpIfReady(&state)
        }
        if case .resume(let continuation) = action {
            continuation.resume()
        }
    }

    func deliverStatus(_ status: UInt16) {
        guard shouldWakeForStatus(status) else { return }
        let action = computeWakeAction()
        resumeIfNeeded(action)
    }

    @inline(__always)
    private func shouldWakeForStatus(_ status: UInt16) -> Bool {
        status == 404 || status == 408
    }

    private func computeWakeAction() -> DeliverAction {
        state.withLockedValue { state in
            switch state.phase {
            case .parked(let continuation):
                state.phase = .idle
                return .resume(continuation)
            case .idle, .closed:
                return .continueAccumulating
            }
        }
    }

    private func resumeIfNeeded(_ action: DeliverAction) {
        if case .resume(let continuation) = action {
            continuation.resume()
        }
    }

    func close() {
        let action: DeliverAction = state.withLockedValue { state in
            switch state.phase {
            case .parked(let continuation):
                state.phase = .closed
                return .resume(continuation)
            case .idle, .closed:
                state.phase = .closed
                return .continueAccumulating
            }
        }
        if case .resume(let continuation) = action {
            continuation.resume()
        }
    }

    private func wakeUpIfReady(_ state: inout State) -> DeliverAction {
        guard state.minimumCount > 0, state.replies.count >= state.minimumCount else {
            return .continueAccumulating
        }
        switch state.phase {
        case .parked(let continuation):
            state.phase = .idle
            return .resume(continuation)
        case .idle, .closed:
            return .continueAccumulating
        }
    }

    private func resolveMinimum(batch: Int, wait: FetchWait) -> Int {
        switch wait {
        case .fill:
            return batch
        case .anyAvailable:
            return 1
        case .atLeast(let count):
            return max(1, min(batch, count))
        }
    }
}
