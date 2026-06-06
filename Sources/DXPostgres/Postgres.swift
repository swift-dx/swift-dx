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

/// Entry point to the minimal DXPostgres client.
///
/// `Postgres` is a namespace, not a value you hold. It hands you a
/// ``PostgresClient`` backed by a pool of plaintext connections. Open one,
/// share it across concurrent callers, and shut it down at the end.
///
/// ```swift
/// let postgres = try Postgres.connect(
///     host: "127.0.0.1", port: 5432,
///     username: "app", password: "", database: "app",
///     applicationName: "myapp", poolSize: 4
/// )
/// defer { postgres.shutdown() }
///
/// let result = try await postgres.execute("SELECT id, email FROM users")
/// let emailColumn = try result.columnIndex(named: "email")
/// for row in result.rows {
///     let id = try row[0].text()
///     let email = row[emailColumn].isNull ? "(none)" : try row[emailColumn].text()
///     print(id, email)
/// }
/// ```
///
/// For a scoped lifetime, ``withClient(host:port:username:password:database:applicationName:poolSize:_:)``
/// shuts the client down whether the body returns or throws.
public enum Postgres {

    /// Opens a client backed by `poolSize` plaintext connections. The connections
    /// are established before this returns, so the first ``PostgresClient/execute(_:)``
    /// does not pay connection setup. Authentication is trust, cleartext, MD5, or
    /// SCRAM as the server requests; pass an empty password for a trust role.
    public static func connect(host: String, port: Int, username: String, password: String, database: String, applicationName: String, poolSize: Int, maxSubscriptions: Int) throws(PostgresError) -> some PostgresClient {
        try PostgresLeasePool(host: host, port: port, username: username, password: password, database: database, applicationName: applicationName, size: poolSize, maxSubscriptions: maxSubscriptions)
    }

    /// Opens a client, runs `body` with it, then shuts it down whether `body`
    /// returns or throws. For scripts, tests, and one-off tools.
    public static func withClient<Result>(host: String, port: Int, username: String, password: String, database: String, applicationName: String, poolSize: Int, maxSubscriptions: Int, _ body: (any PostgresClient) async throws -> Result) async throws -> Result {
        let client: any PostgresClient = try connect(host: host, port: port, username: username, password: password, database: database, applicationName: applicationName, poolSize: poolSize, maxSubscriptions: maxSubscriptions)
        do {
            let result = try await body(client)
            client.shutdown()
            return result
        } catch {
            client.shutdown()
            throw error
        }
    }
}
