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

public struct RedisConfiguration: Sendable {

    public let endpoints: [RedisEndpoint]
    public let credentials: RedisCredentials
    public let database: RedisDatabaseIndex
    public let transportSecurity: RedisTransportSecurity
    // Caller-owned. The client never shuts this group down; it must outlive the
    // client. The default is the process-wide shared singleton.
    public let eventLoopGroup: EventLoopGroup
    public let connectTimeout: TimeAmount
    // Hard cap on open connections, i.e. the maximum number of Redis operations
    // in flight at once. Callers beyond this do not fail: the resilience layer
    // waits for a connection to free and only surfaces an error if none does
    // within its budget. Size this to the steady-state concurrency you want to
    // run in parallel against one server.
    public let maxConnections: Int
    // Soft cap on idle connections retained when no caller wants them. Released
    // connections beyond this are closed. Defaulting it to maxConnections keeps
    // every opened connection warm for reuse.
    public let maxIdleConnections: Int
    // Idle connections older than this are evicted on the next acquire.
    public let idleTimeout: TimeAmount
    // Hard cap on a connection's total lifetime; older connections are closed on
    // release so DNS and credential rotations take effect across the pool.
    public let maxLifetime: TimeAmount
    // Maximum RESP array nesting accepted from the server before parsing throws
    // RedisError.responseDepthLimitExceeded.
    public let responseDepthLimit: Int
    // Maximum bulk-string length accepted from the server before parsing throws
    // RedisError.malformedLength. Defaults to Redis's 512 MiB proto-max-bulk-len.
    public let maxBulkBytes: Int
    // How the client transparently rides out transient failures (pool at
    // capacity, dropped connection, brief server restart) so callers never see
    // them. See RedisResilience; by default each operation times out after 10
    // seconds and transient failures are retried within that window.
    public let resilience: RedisResilience
    // Where the client emits operational events: connectivity at startup, and a
    // warning when the server is unreachable. Defaults to a logger labelled
    // "swift.dx.redis"; inject your own to route these into the application's
    // logging backend.
    public let logger: Logger

    public init(endpoints: [RedisEndpoint], credentials: RedisCredentials = .none, database: RedisDatabaseIndex = .zero, transportSecurity: RedisTransportSecurity = .plaintext, eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton, connectTimeout: TimeAmount = .seconds(10), maxConnections: Int = 16, maxIdleConnections: Int = 16, idleTimeout: TimeAmount = .seconds(60), maxLifetime: TimeAmount = .minutes(30), responseDepthLimit: Int = 64, maxBulkBytes: Int = 512 * 1024 * 1024, resilience: RedisResilience = RedisResilience(), logger: Logger = Logger(label: "swift.dx.redis")) {
        self.endpoints = endpoints
        self.credentials = credentials
        self.database = database
        self.transportSecurity = transportSecurity
        self.eventLoopGroup = eventLoopGroup
        self.connectTimeout = connectTimeout
        self.maxConnections = maxConnections
        self.maxIdleConnections = maxIdleConnections
        self.idleTimeout = idleTimeout
        self.maxLifetime = maxLifetime
        self.responseDepthLimit = responseDepthLimit
        self.maxBulkBytes = maxBulkBytes
        self.resilience = resilience
        self.logger = logger
    }

    public init(endpoint: RedisEndpoint, credentials: RedisCredentials = .none, database: RedisDatabaseIndex = .zero, transportSecurity: RedisTransportSecurity = .plaintext, eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton, connectTimeout: TimeAmount = .seconds(10), maxConnections: Int = 16, maxIdleConnections: Int = 16, idleTimeout: TimeAmount = .seconds(60), maxLifetime: TimeAmount = .minutes(30), responseDepthLimit: Int = 64, maxBulkBytes: Int = 512 * 1024 * 1024, resilience: RedisResilience = RedisResilience(), logger: Logger = Logger(label: "swift.dx.redis")) {
        self.init(
            endpoints: [endpoint],
            credentials: credentials,
            database: database,
            transportSecurity: transportSecurity,
            eventLoopGroup: eventLoopGroup,
            connectTimeout: connectTimeout,
            maxConnections: maxConnections,
            maxIdleConnections: maxIdleConnections,
            idleTimeout: idleTimeout,
            maxLifetime: maxLifetime,
            responseDepthLimit: responseDepthLimit,
            maxBulkBytes: maxBulkBytes,
            resilience: resilience,
            logger: logger
        )
    }

    func poolConfiguration(observability: RedisObservability) -> RedisConnectionPool.Configuration {
        .init(
            endpoints: endpoints,
            credentials: credentials,
            database: database,
            transportSecurity: transportSecurity,
            eventLoopGroup: eventLoopGroup,
            connectTimeout: connectTimeout,
            requestTimeout: resilience.requestTimeout,
            maxConnections: maxConnections,
            maxIdleConnections: maxIdleConnections,
            idleTimeout: idleTimeout,
            maxLifetime: maxLifetime,
            responseDepthLimit: responseDepthLimit,
            maxBulkBytes: maxBulkBytes,
            observability: observability
        )
    }
}
