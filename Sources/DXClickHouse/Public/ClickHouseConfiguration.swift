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

// Top-level connection configuration consumed by both the ad-hoc
// `ClickHouse.connect` path and the long-running `ClickHouseService`
// service-lifecycle integration. One configuration vocabulary so
// behaviour is identical regardless of which entry point a caller uses.
//
// Field roles:
//
//   * endpoints      — one or more host:port pairs. A single endpoint is
//                      the typical case; multi-endpoint configurations
//                      hand the list to the underlying connection layer
//                      for failover.
//   * user/password/database — auth context applied to every connection
//                      opened from this configuration.
//   * shutdownGracePeriod — when the service is asked to shut down, in-
//                      flight queries are allowed up to this Duration to
//                      drain before the underlying connection is closed.
//                      Defaults to 30 seconds, matching the ServiceGroup
//                      cancellation contract typical operators expect.
//   * logger         — destination for service-level lifecycle events
//                      (startup, shutdown, drain completion, drain
//                      timeout). Defaults to a no-op logger so libraries
//                      that don't wire logging see no output.
public struct ClickHouseConfiguration: Sendable {

    public let endpoints: [ClickHouseEndpoint]
    public let user: String
    public let password: String
    public let database: String
    public let shutdownGracePeriod: Duration
    public let logger: Logger

    // Multi-endpoint constructor. An empty endpoints list cannot produce a
    // usable configuration — the connection layer reads the first endpoint
    // to dial — so it is rejected with a typed error at the boundary rather
    // than trapping the process. Building the list dynamically (service
    // discovery, environment parsing) that resolves to nothing is a
    // recoverable application condition, not a programmer invariant.
    public init(
        endpoints: [ClickHouseEndpoint],
        user: String = "default",
        password: String = "",
        database: String = "default",
        shutdownGracePeriod: Duration = .seconds(30),
        logger: Logger = Logger(label: "swift-dx.clickhouse", factory: { _ in SwiftLogNoOpLogHandler() })
    ) throws(ClickHouseError) {
        guard !endpoints.isEmpty else {
            throw .protocolError(
                stage: "configuration",
                message: "ClickHouseConfiguration requires at least one endpoint; the endpoints list was empty"
            )
        }
        self.init(
            validatedEndpoints: endpoints,
            user: user,
            password: password,
            database: database,
            shutdownGracePeriod: shutdownGracePeriod,
            logger: logger
        )
    }

    // Single-endpoint convenience. A host/port pair always yields exactly
    // one endpoint, so this form cannot reach the empty-list state and
    // stays non-throwing.
    public init(
        host: String,
        port: Int,
        user: String = "default",
        password: String = "",
        database: String = "default",
        shutdownGracePeriod: Duration = .seconds(30),
        logger: Logger = Logger(label: "swift-dx.clickhouse", factory: { _ in SwiftLogNoOpLogHandler() })
    ) {
        self.init(
            validatedEndpoints: [ClickHouseEndpoint(host: host, port: port)],
            user: user,
            password: password,
            database: database,
            shutdownGracePeriod: shutdownGracePeriod,
            logger: logger
        )
    }

    private init(
        validatedEndpoints: [ClickHouseEndpoint],
        user: String,
        password: String,
        database: String,
        shutdownGracePeriod: Duration,
        logger: Logger
    ) {
        self.endpoints = validatedEndpoints
        self.user = user
        self.password = password
        self.database = database
        self.shutdownGracePeriod = shutdownGracePeriod
        self.logger = logger
    }
}
