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

    // Policy for what `acquire` does when the pool is saturated at
    // `maxConnections`. `failImmediatelyWhenExhausted` surfaces
    // `poolExhausted` on the next acquire without parking the caller;
    // `waitUpTo` parks for the supplied duration and then surfaces
    // `poolWaitTimeout`. There is no "wait indefinitely" case by
    // design: a request without a deadline is an outage waiting to
    // happen, and forcing a deliberate choice keeps that decision
    // explicit at construction time.
    public enum PoolAcquireTimeout: Sendable, Equatable {

        case failImmediatelyWhenExhausted
        case waitUpTo(TimeAmount)

    }

}
