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

// One host:port pair the pool can target. Multi-endpoint pools take an
// ordered array of these and round-robin across them on every new
// connection attempt; if a given endpoint is unreachable the pool
// fails over to the next entry and only surfaces
// `ClickHouseError.endpointsExhausted` after every entry has been
// tried.
//
// Endpoints are pure address tuples — they carry no per-host
// credentials, since the auth context lives on the pool's
// `Configuration`. A future change might add per-endpoint auth
// overrides; until then a homogeneous credential set is the documented
// contract.
public struct ClickHouseEndpoint: Sendable, Equatable, Hashable, CustomStringConvertible {

    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    public var description: String { "\(host):\(port)" }
}
