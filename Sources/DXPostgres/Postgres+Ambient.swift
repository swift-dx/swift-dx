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

import ServiceLifecycle

extension Postgres {

    /// Opens a pooled client from a configuration.
    public static func connect(_ configuration: PostgresConfiguration) throws(PostgresError) -> some PostgresClient {
        try PostgresLeasePool(host: configuration.host, port: configuration.port, username: configuration.username, password: configuration.password, database: configuration.database, applicationName: configuration.applicationName, size: configuration.poolSize)
    }

    /// Opens a pooled client that also runs as a ServiceLifecycle `Service`. Add the
    /// returned value to a `ServiceGroup` so the pool is torn down on graceful
    /// shutdown, and use the same value to run queries or bind it as the ambient
    /// client with ``withCurrent(_:_:)``.
    public static func service(_ configuration: PostgresConfiguration) throws(PostgresError) -> some PostgresClient & Service {
        try PostgresLeasePool(host: configuration.host, port: configuration.port, username: configuration.username, password: configuration.password, database: configuration.database, applicationName: configuration.applicationName, size: configuration.poolSize)
    }

    enum Ambient: Sendable {

        case unbound
        case bound(any PostgresClient)
    }

    @TaskLocal static var ambient: Ambient = .unbound

    /// Binds `client` as the ambient client for the duration of `body`. Code in the
    /// same structured-task tree reads it back with ``current()`` or runs queries
    /// directly with ``execute(_:)`` without being handed the client. The binding
    /// propagates to child tasks and task groups but not across `Task.detached`.
    public static func withCurrent<Result>(_ client: any PostgresClient, _ body: () async throws -> Result) async rethrows -> Result {
        try await $ambient.withValue(.bound(client)) {
            try await body()
        }
    }

    /// Returns the ambient client bound by an enclosing ``withCurrent(_:_:)``. Throws
    /// ``PostgresError/noCurrentClient`` when no client is bound in the current task
    /// tree, rather than returning a null or trapping.
    public static func current() throws(PostgresError) -> any PostgresClient {
        guard case .bound(let client) = ambient else {
            throw PostgresError.noCurrentClient
        }
        return client
    }

    /// Runs a statement on the ambient client bound by ``withCurrent(_:_:)``.
    public static func execute(_ sql: String) async throws(PostgresError) -> PostgresResult {
        try await current().execute(sql)
    }

    /// Runs a parameterized statement on the ambient client.
    public static func query(_ statement: PostgresStatement) async throws(PostgresError) -> PostgresResult {
        try await current().query(statement)
    }

    /// Runs a parameterized statement on the ambient client and decodes the rows.
    public static func query<T: Decodable & Sendable>(_ statement: PostgresStatement, as type: T.Type) async throws(PostgresError) -> [T] {
        try await current().query(statement, as: type)
    }
}
