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

/// The network location of a PostgreSQL server. The port defaults to the
/// PostgreSQL well-known port 5432; pass 5433 to reach a YugabyteDB YSQL node or
/// any other wire-compatible server on its own port.
public struct PostgresEndpoint: Sendable, Hashable {

    public let host: String
    public let port: Int

    public init(host: String, port: Int = 5432) {
        self.host = host
        self.port = port
    }
}

extension PostgresEndpoint: CustomStringConvertible {

    public var description: String {
        "\(host):\(port)"
    }
}
