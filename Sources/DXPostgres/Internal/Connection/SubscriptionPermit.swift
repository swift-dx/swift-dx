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

// A claim on one slot of a client's subscription limit, held for the life of a
// subscription and released exactly once when it closes. The release is
// idempotent so close, deinit, and a loop-thread teardown can all call it safely.
// An unlimited permit carries no client slot and is used by raw, caller-managed
// subscriptions that the limit does not govern.
final class SubscriptionPermit: Sendable {

    private let onRelease: @Sendable () -> Void
    private let released = Atomic<Bool>(false)

    init(onRelease: @escaping @Sendable () -> Void) {
        self.onRelease = onRelease
    }

    static func unlimited() -> SubscriptionPermit {
        SubscriptionPermit(onRelease: {})
    }

    func release() {
        let (exchanged, _) = released.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing)
        if exchanged {
            onRelease()
        }
    }
}
