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

/// Everything needed to open a pooled connection to PostgreSQL. Pass it to
/// ``Postgres/connect(_:)`` for a client, or to ``Postgres/service(_:)`` for a
/// client that also runs as a ServiceLifecycle `Service`. The connection is
/// plaintext; for a trust role leave `password` empty.
///
/// `poolSize` bounds the connections used for queries: callers above it wait for a
/// free one. `maxSubscriptions` bounds the dedicated connections used by ambient
/// ``Postgres/subscribe(channels:)`` and ``Postgres/watchTable(table:)``: opening
/// one past the limit fails fast with
/// ``PostgresError/subscriptionLimitReached(limit:)``, and a slot frees when a
/// subscription closes. The two bound separate connection sets; the total
/// PostgreSQL footprint is at most `poolSize + maxSubscriptions`.
public struct PostgresConfiguration: Sendable {

    public let host: String
    public let port: Int
    public let username: String
    public let password: String
    public let database: String
    public let applicationName: String
    public let searchPath: PostgresSearchPath
    public let poolSize: Int
    public let maxSubscriptions: Int

    public init(host: String, port: Int, username: String, password: String, database: String, applicationName: String, searchPath: PostgresSearchPath, poolSize: Int, maxSubscriptions: Int) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.applicationName = applicationName
        self.searchPath = searchPath
        self.poolSize = poolSize
        self.maxSubscriptions = maxSubscriptions
    }
}
