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

// A live subscription. It stays active — re-subscribing across reconnects — until
// `cancel()` is called; dropping the handle does not unsubscribe, matching the
// "until explicitly unsubscribed" contract. Cancelling stops delivery to the
// handler immediately and sends the UNSUBSCRIBE to the server.
public final class RedisSubscription: Sendable {

    let id: UInt64
    private let manager: RedisSubscriptionManager

    init(id: UInt64, manager: RedisSubscriptionManager) {
        self.id = id
        self.manager = manager
    }

    public func cancel() {
        manager.cancel(id)
    }
}
