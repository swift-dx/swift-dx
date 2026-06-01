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

/// A cumulative snapshot of client activity since the ``RedisClient`` was created.
/// The counts are monotonic; sample them periodically and difference successive
/// snapshots to derive rates.
///
/// ``commandsTotal`` counts every completed operation (a single command or a
/// pipeline batch), success or failure; ``commandErrorsTotal`` counts the failing
/// subset, so the error ratio is `commandErrorsTotal / commandsTotal`.
/// ``retriesTotal`` counts transient-failure retry attempts, ``poolTimeoutsTotal``
/// counts callers that gave up waiting for a connection, and
/// ``connectionsOpenedTotal`` counts physical connections established.
public struct RedisClientMetrics: Sendable, Equatable {

    public let commandsTotal: UInt64
    public let commandErrorsTotal: UInt64
    public let retriesTotal: UInt64
    public let poolTimeoutsTotal: UInt64
    public let connectionsOpenedTotal: UInt64
    public let totalCommandDurationNanos: UInt64

    public var meanCommandDurationNanos: UInt64 {
        commandsTotal == 0 ? 0 : totalCommandDurationNanos / commandsTotal
    }
}
