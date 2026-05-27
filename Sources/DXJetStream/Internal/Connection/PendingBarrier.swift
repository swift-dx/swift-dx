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

final class PendingBarrier: Sendable {

    private let remaining: ManagedAtomic<Int64>
    private let waiterState: NIOLockedValueBox<WaiterState>

    private enum WaiterState: Sendable {

        case idle
        case parked(CheckedContinuation<Void, Never>)
    }

    private enum ArriveAction {

        case noWaiter
        case resume(CheckedContinuation<Void, Never>)
    }

    private enum RegisterAction {

        case parked
        case resumeImmediately(CheckedContinuation<Void, Never>)
    }

    init(count: Int) {
        self.remaining = ManagedAtomic<Int64>(Int64(count))
        self.waiterState = NIOLockedValueBox(.idle)
    }

    @discardableResult
    func arrive() -> Bool {
        let new = remaining.wrappingDecrementThenLoad(ordering: .acquiringAndReleasing)
        guard new <= 0 else { return false }
        let action: ArriveAction = waiterState.withLockedValue { state in
            switch state {
            case .idle:
                return .noWaiter
            case .parked(let continuation):
                state = .idle
                return .resume(continuation)
            }
        }
        if case .resume(let continuation) = action {
            continuation.resume()
        }
        return true
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if remaining.load(ordering: .acquiring) <= 0 {
                continuation.resume()
                return
            }
            let action: RegisterAction = waiterState.withLockedValue { state in
                if remaining.load(ordering: .acquiring) <= 0 {
                    return .resumeImmediately(continuation)
                }
                state = .parked(continuation)
                return .parked
            }
            if case .resumeImmediately(let c) = action {
                c.resume()
            }
        }
    }
}
