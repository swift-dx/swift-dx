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

final class PendingSingle: Sendable {

    private let state: NIOLockedValueBox<State>

    private enum State: Sendable {

        case idle
        case parked(CheckedContinuation<NatsMessage, any Error>)
        case completed(Result<NatsMessage, any Error>)
    }

    private enum WaitAction {

        case parked
        case deliver(Result<NatsMessage, any Error>)
    }

    private enum CompleteAction {

        case stored
        case resume(CheckedContinuation<NatsMessage, any Error>, Result<NatsMessage, any Error>)
    }

    init() {
        self.state = NIOLockedValueBox(.idle)
    }

    func wait() async throws -> NatsMessage {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NatsMessage, any Error>) in
            let action: WaitAction = state.withLockedValue { state in
                switch state {
                case .idle:
                    state = .parked(continuation)
                    return .parked
                case .completed(let result):
                    return .deliver(result)
                case .parked:
                    return .deliver(.failure(JetStreamError.protocolError(reason: "PendingSingle.wait called twice")))
                }
            }
            if case .deliver(let result) = action {
                continuation.resume(with: result)
            }
        }
    }

    func complete(_ result: Result<NatsMessage, any Error>) {
        let action: CompleteAction = state.withLockedValue { state in
            switch state {
            case .idle:
                state = .completed(result)
                return .stored
            case .completed:
                return .stored
            case .parked(let continuation):
                state = .completed(result)
                return .resume(continuation, result)
            }
        }
        if case .resume(let continuation, let result) = action {
            continuation.resume(with: result)
        }
    }
}
