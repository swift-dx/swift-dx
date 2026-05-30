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

    public init(
        endpoints: [ClickHouseEndpoint],
        user: String = "default",
        password: String = "",
        database: String = "default",
        shutdownGracePeriod: Duration = .seconds(30),
        logger: Logger = Logger(label: "swift-dx.clickhouse", factory: { _ in SwiftLogNoOpLogHandler() })
    ) {
        precondition(!endpoints.isEmpty, "ClickHouseConfiguration requires at least one endpoint")
        self.endpoints = endpoints
        self.user = user
        self.password = password
        self.database = database
        self.shutdownGracePeriod = shutdownGracePeriod
        self.logger = logger
    }

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
            endpoints: [ClickHouseEndpoint(host: host, port: port)],
            user: user,
            password: password,
            database: database,
            shutdownGracePeriod: shutdownGracePeriod,
            logger: logger
        )
    }
}
