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

// Per-endpoint health snapshot, surfaced through pool stats. Operators
// use this to identify which specific endpoint is in cooldown rather
// than just the aggregate count, which is what the `unhealthyEndpointCount`
// field reports.
public struct ClickHouseEndpointHealth: Sendable, Equatable {

    public let endpoint: ClickHouseEndpoint
    public let status: Status

    public init(endpoint: ClickHouseEndpoint, status: Status) {
        self.endpoint = endpoint
        self.status = status
    }

    public enum Status: String, Sendable, Equatable, CaseIterable {

        // No recent connect failure recorded, or any recorded failure
        // has already aged past the configured cooldown window.
        case healthy

        // Recent connect failure within the cooldown window. The pool
        // skips this endpoint when picking the next candidate to dial,
        // unless every endpoint is in cooldown.
        case coolingDown

    }

}
