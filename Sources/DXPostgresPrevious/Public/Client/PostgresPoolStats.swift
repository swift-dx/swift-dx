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

/// A point-in-time snapshot of the connection pool: how many connections are
/// idle and reusable, how many are currently leased to a request, and the
/// configured hard cap. Useful for capacity dashboards and saturation alerts.
public struct PostgresPoolStats: Sendable, Equatable {

    public let idleConnections: Int
    public let inUseConnections: Int
    public let maxConnections: Int

    public var totalConnections: Int {
        idleConnections + inUseConnections
    }
}
