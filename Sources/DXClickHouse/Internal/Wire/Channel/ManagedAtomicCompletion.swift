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

import Synchronization

// Two-state flag (`pending` -> `completed` or `pending` -> `cancelled`)
// used by the connection's cancellation guard to decide whether to
// close the channel. A normal-path completion races with the
// `onCancel` callback that fires when the public stream's
// `onTermination` cancels the inner Task on consumer-end-of-iteration:
// without this flag, every successful query would trip the
// cancellation close path on the way down.
//
// `markAndCheckPending()` is the callback's atomic test-and-set: it
// returns `true` only on the first transition out of `pending`, which
// is the cancel-while-in-flight case. `markCompleted()` is the
// success-path's set, swallowed if the flag has already moved.
//
// State + lock are bundled in stdlib `Mutex<State>` (Swift 6+) so the
// lock can't be acquired without the value being visible — the type
// system enforces lock-held access.
final class ManagedAtomicCompletion: Sendable {

    private let state = Mutex<State>(.pending)

    private enum State: Sendable {

        case pending
        case completed
        case cancelled

    }

    func markCompleted() {
        state.withLock { state in
            if case .pending = state {
                state = .completed
            }
        }
    }

    func markAndCheckPending() -> Bool {
        state.withLock { state in
            if case .pending = state {
                state = .cancelled
                return true
            }
            return false
        }
    }

}
