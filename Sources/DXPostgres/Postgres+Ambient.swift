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
        try await PostgresInstrumentation.trace("execute") { try await current().execute(sql) }
    }

    /// Runs a parameterized statement on the ambient client.
    public static func query(_ statement: PostgresStatement) async throws(PostgresError) -> PostgresResult {
        try await PostgresInstrumentation.trace("query") { try await current().query(statement) }
    }

    /// Runs a parameterized statement on the ambient client and decodes the rows.
    public static func query<T: Decodable & Sendable>(_ statement: PostgresStatement, as type: T.Type) async throws(PostgresError) -> [T] {
        try await PostgresInstrumentation.trace("query") { try await current().query(statement, as: type) }
    }

    /// Publishes `payload` on `channel` through the ambient client, reaching every
    /// session currently subscribed to it.
    public static func notify(channel: String, payload: String) async throws(PostgresError) {
        try await PostgresInstrumentation.trace("notify") { try await current().notify(channel: channel, payload: payload) }
    }

    /// Runs a transaction on the ambient client: every statement on the handed-in
    /// ``PostgresTransaction`` commits together on return, or rolls back on a throw.
    public static func transaction<Result: Sendable>(_ body: @escaping @Sendable (PostgresTransaction) throws -> Result) async throws -> Result {
        try await PostgresInstrumentation.traceRethrowing("transaction") { try await current().transaction(body) }
    }

    /// Subscribes to `channels` using the ambient client's connection settings, so a
    /// subscription needs no configuration of its own. The returned listener owns a
    /// dedicated, self-healing connection separate from the pool.
    public static func subscribe(channels: [String]) throws(PostgresError) -> PostgresListener {
        try PostgresListener(target: subscriptionTarget(), channels: channels)
    }

    /// Watches `table` through the ambient client, installing the change trigger and
    /// subscribing for you. The publish channel is derived from the table name.
    public static func watchTable(table: String) throws(PostgresError) -> PostgresListener {
        try watchTable(target: subscriptionTarget(), table: table)
    }

    /// Watches `table` for rows matching `filter` through the ambient client. The
    /// filter runs in the server, so only matching changes reach the listener.
    public static func watchTable(table: String, where filter: String) throws(PostgresError) -> PostgresListener {
        try watchTable(target: subscriptionTarget(), table: table, where: filter)
    }

    private static func subscriptionTarget() throws(PostgresError) -> PostgresConnectionTarget {
        guard let provider = try current() as? PostgresSubscriptionProvider, case .reconnectable(let target) = provider.listenerSource else {
            throw PostgresError.noCurrentClient
        }
        return target
    }
}
