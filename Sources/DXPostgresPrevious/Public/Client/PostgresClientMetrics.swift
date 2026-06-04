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

/// A cumulative snapshot of client activity since the ``PostgresClient`` was
/// created. The counts are monotonic; sample them periodically and difference
/// successive snapshots to derive rates (queries per second, error ratio).
///
/// ``queriesTotal`` counts every completed logical query, success or failure;
/// ``queryErrorsTotal`` counts the failing subset, so the error ratio is
/// `queryErrorsTotal / queriesTotal`. ``retriesTotal`` counts individual
/// transient-failure retry attempts, ``poolTimeoutsTotal`` counts callers that
/// gave up waiting for a connection, and ``connectionsOpenedTotal`` counts
/// physical connections established (a proxy for reconnect churn).
public struct PostgresClientMetrics: Sendable, Equatable {

    public let queriesTotal: UInt64
    public let queryErrorsTotal: UInt64
    public let retriesTotal: UInt64
    public let poolTimeoutsTotal: UInt64
    public let connectionsOpenedTotal: UInt64
    public let totalQueryDurationNanos: UInt64

    public var meanQueryDurationNanos: UInt64 {
        queriesTotal == 0 ? 0 : totalQueryDurationNanos / queriesTotal
    }
}
