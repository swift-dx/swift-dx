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

public struct RedisPoolStats: Sendable, Hashable {

    public let idleConnections: Int
    public let inUseConnections: Int
    public let maxConnections: Int

    public init(idleConnections: Int, inUseConnections: Int, maxConnections: Int) {
        self.idleConnections = idleConnections
        self.inUseConnections = inUseConnections
        self.maxConnections = maxConnections
    }
}
