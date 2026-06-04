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

import Logging
import NIOCore
import NIOPosix

/// Everything needed to open and run a ``PostgresClient``: where the server is,
/// who to connect as, which database, transport security, and the pool sizing
/// and timeout budgets. One instance describes one logical client; reuse the
/// resulting client for the process lifetime rather than rebuilding it per
/// request.
public struct PostgresConfiguration: Sendable {

    public let endpoints: [PostgresEndpoint]
    public let credentials: PostgresCredentials
    public let database: PostgresDatabaseName
    public let transportSecurity: PostgresTransportSecurity
    public let applicationName: String
    // Caller-owned. The client never shuts this group down; it must outlive the
    // client. The default is the process-wide shared singleton.
    public let eventLoopGroup: EventLoopGroup
    public let connectTimeout: TimeAmount
    // Bounds a single request end to end: acquiring a connection plus the query
    // round-trip. When it elapses the connection is closed and the operation
    // throws PostgresError.timedOut, never a result the server did not send.
    public let requestTimeout: TimeAmount
    // Hard cap on open connections, i.e. the maximum number of statements in
    // flight at once. A caller beyond the cap parks in a FIFO queue until a
    // connection is released, then proceeds; size this to the steady-state
    // concurrency you want to run in parallel against one server.
    public let maxConnections: Int
    // Soft cap on idle connections retained when no caller wants them; released
    // connections beyond this are closed.
    public let maxIdleConnections: Int
    // Idle connections older than this are evicted on the next acquire.
    public let idleTimeout: TimeAmount
    // Hard cap on a connection's total lifetime; older connections are closed on
    // release so DNS and credential rotations take effect across the pool.
    public let maxLifetime: TimeAmount
    // How the client transparently rides out transient failures (dropped
    // connection, brief restart, momentarily full pool) so single queries
    // recover on their own. See PostgresResilience; defaults to retrying within
    // the request-timeout budget.
    public let resilience: PostgresResilience
    // Where the client emits operational events. Defaults to a logger labelled
    // "swift.dx.postgres"; inject your own to route these into the application's
    // logging backend.
    public let logger: Logger

    public init(endpoints: [PostgresEndpoint], credentials: PostgresCredentials, database: PostgresDatabaseName, transportSecurity: PostgresTransportSecurity = .plaintext, applicationName: String = "swift-dx", eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton, connectTimeout: TimeAmount = .seconds(10), requestTimeout: TimeAmount = .seconds(30), maxConnections: Int = 16, maxIdleConnections: Int = 16, idleTimeout: TimeAmount = .seconds(60), maxLifetime: TimeAmount = .minutes(30), resilience: PostgresResilience = PostgresResilience(), logger: Logger = Logger(label: "swift.dx.postgres")) {
        self.endpoints = endpoints
        self.credentials = credentials
        self.database = database
        self.transportSecurity = transportSecurity
        self.applicationName = applicationName
        self.eventLoopGroup = eventLoopGroup
        self.connectTimeout = connectTimeout
        self.requestTimeout = requestTimeout
        self.maxConnections = maxConnections
        self.maxIdleConnections = maxIdleConnections
        self.idleTimeout = idleTimeout
        self.maxLifetime = maxLifetime
        self.resilience = resilience
        self.logger = logger
    }

    public init(endpoint: PostgresEndpoint, credentials: PostgresCredentials, database: PostgresDatabaseName, transportSecurity: PostgresTransportSecurity = .plaintext, applicationName: String = "swift-dx", eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton, connectTimeout: TimeAmount = .seconds(10), requestTimeout: TimeAmount = .seconds(30), maxConnections: Int = 16, maxIdleConnections: Int = 16, idleTimeout: TimeAmount = .seconds(60), maxLifetime: TimeAmount = .minutes(30), resilience: PostgresResilience = PostgresResilience(), logger: Logger = Logger(label: "swift.dx.postgres")) {
        self.init(endpoints: [endpoint], credentials: credentials, database: database, transportSecurity: transportSecurity, applicationName: applicationName, eventLoopGroup: eventLoopGroup, connectTimeout: connectTimeout, requestTimeout: requestTimeout, maxConnections: maxConnections, maxIdleConnections: maxIdleConnections, idleTimeout: idleTimeout, maxLifetime: maxLifetime, resilience: resilience, logger: logger)
    }

    func poolConfiguration(observability: PostgresObservability) -> PostgresConnectionPool.Configuration {
        .init(endpoints: endpoints, credentials: credentials, database: database, transportSecurity: transportSecurity, applicationName: applicationName, eventLoopGroup: eventLoopGroup, connectTimeout: connectTimeout, requestTimeout: requestTimeout, maxConnections: maxConnections, maxIdleConnections: maxIdleConnections, idleTimeout: idleTimeout, maxLifetime: maxLifetime, observability: observability)
    }
}
