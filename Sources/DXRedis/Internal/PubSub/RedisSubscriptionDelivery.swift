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

// One queued delivery for a subscription's consumer task: a channel message
// carries the channel it arrived on; a pattern message carries both the pattern
// that matched and the concrete channel.
enum RedisSubscriptionDelivery: Sendable {

    case channel(RedisChannel, RedisMessage)
    case pattern(RedisPattern, RedisChannel, RedisMessage)
}
