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

import Testing
import NIOConcurrencyHelpers
@testable import DXJetStream

@Suite
struct SubscriptionHandleTests {

    @Test
    func cancel_invokesStoredClosure() {
        let counter = NIOLockedValueBox(0)
        let handle = SubscriptionHandle {
            counter.withLockedValue { $0 += 1 }
        }
        handle.cancel()
        #expect(counter.withLockedValue { $0 } == 1)
    }

    @Test
    func cancel_canBeCalledMultipleTimes() {
        let counter = NIOLockedValueBox(0)
        let handle = SubscriptionHandle {
            counter.withLockedValue { $0 += 1 }
        }
        handle.cancel()
        handle.cancel()
        handle.cancel()
        #expect(counter.withLockedValue { $0 } == 3)
    }
}
