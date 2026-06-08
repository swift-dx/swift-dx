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

// The parameters needed to open one connection, kept so a pool worker can rebuild
// its connection from scratch after the old one dies. It is the connect half of
// PostgresConfiguration without the pool size: a single connection has no notion
// of how many siblings share its pool.
struct PostgresConnectionTarget: Sendable, Equatable {

    let host: String
    let port: Int
    let username: String
    let password: String
    let database: String
    let applicationName: String
    let searchPath: PostgresSearchPath

    func connect() throws(PostgresError) -> BlockingPostgresConnection {
        try BlockingPostgresConnection.connect(host: host, port: port, username: username, password: password, database: database, applicationName: applicationName, searchPath: searchPath)
    }
}
