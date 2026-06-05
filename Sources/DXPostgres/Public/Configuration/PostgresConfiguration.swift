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
public struct PostgresConfiguration: Sendable {

    public let host: String
    public let port: Int
    public let username: String
    public let password: String
    public let database: String
    public let applicationName: String
    public let poolSize: Int

    public init(host: String, port: Int, username: String, password: String, database: String, applicationName: String, poolSize: Int) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.applicationName = applicationName
        self.poolSize = poolSize
    }
}
