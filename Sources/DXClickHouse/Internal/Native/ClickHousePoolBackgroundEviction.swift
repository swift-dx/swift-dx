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

import NIOCore

extension ClickHouseClient {

    // Policy for when the pool reaps dead-channel and time-expired
    // idle entries. `onAcquireOnly` runs eviction lazily on every
    // `acquire` call (simple, deterministic, no orphan task
    // lifecycle). `every` additionally spawns a background task that
    // sweeps at the supplied cadence, which is necessary for services
    // with long quiet periods between bursts where eviction would
    // otherwise stall until the next `acquire`.
    public enum PoolBackgroundEviction: Sendable, Equatable {

        case onAcquireOnly
        case every(TimeAmount)

    }

}
