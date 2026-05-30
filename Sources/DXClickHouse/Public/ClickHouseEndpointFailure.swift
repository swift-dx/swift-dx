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

// Aggregated per-endpoint failure record, returned inside
// `ClickHouseError.endpointsExhausted` when the pool exhausts its
// configured endpoint list. Callers can iterate to surface a precise
// per-host diagnostic.
public struct ClickHouseEndpointFailure: Sendable, Equatable, CustomStringConvertible {

    public let host: String
    public let port: Int
    public let reason: String

    public init(host: String, port: Int, reason: String) {
        self.host = host
        self.port = port
        self.reason = reason
    }

    public var description: String {
        "\(host):\(port) -> \(reason)"
    }
}
