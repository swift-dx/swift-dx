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

import NIOCore

extension ClickHouseClient {

    public struct Configuration: Sendable {

        public let endpoints: [ClickHouseEndpoint]
        public let database: String
        public let user: String
        public let password: String
        public let clientName: String
        public let clientVersionMajor: UInt64
        public let clientVersionMinor: UInt64
        public let advertisedRevision: UInt64
        // Hard cap on how many connections the pool will open
        // concurrently. A burst beyond this either parks (with
        // `acquireTimeout`) or surfaces `poolExhausted` immediately.
        public let maxConnections: Int
        // Soft cap on how many idle connections the pool will keep
        // when no caller wants them. Released connections in excess
        // are closed instead of parking. Setting this above
        // `maxConnections` is harmless (effective cap is the min).
        public let maxIdleConnections: Int
        // Idle connections older than this are evicted on the next
        // sweep (lazy on `acquire` plus the periodic
        // `backgroundEvictionInterval` task). Bounds how long a stale
        // socket can sit unused before being closed.
        public let idleTimeout: TimeAmount
        // Hard cap on how long a single connection lives, regardless
        // of activity. Forces periodic recycling so DNS rebalances,
        // server upgrades, and certificate rotations naturally take
        // effect across the pool. Enforced on release: a connection
        // older than this is closed instead of returning to idle.
        public let maxLifetime: TimeAmount
        // Bounds the time spent dialling a fresh connection. Applied
        // independently to NIO's TCP connect AND the post-connect
        // handshake (Hello + Addendum + pipeline swap), so worst case
        // the call takes up to ~2x this value.
        public let connectTimeout: TimeAmount
        // Whether (and after what idle duration) the pool Ping's an
        // idle connection before reusing it. `.never` skips the check;
        // `.afterIdleFor(...)` Ping's connections idle longer than
        // the threshold and replaces any that fail. A few seconds is
        // the typical production setting.
        public let preflightPingThreshold: PoolPreflightPing
        // Whether an `acquire` waiting on a free connection (pool
        // saturated at `maxConnections`) eventually gives up.
        // `.failImmediatelyWhenExhausted` surfaces `poolExhausted`
        // without parking; `.waitUpTo(...)` parks for the supplied
        // duration and then surfaces `poolWaitTimeout`. Set the wait
        // to the worst-case latency you'd accept on a request to fail
        // fast under load.
        public let acquireTimeout: PoolAcquireTimeout
        // Whether the pool runs a background eviction sweep.
        // `.onAcquireOnly` leaves eviction to the next `acquire`;
        // `.every(...)` spawns a background task that sweeps at the
        // supplied cadence so dead-channel and time-expired entries
        // are reaped even when no `acquire` is happening. Necessary
        // for services with long quiet periods between bursts.
        public let backgroundEvictionInterval: PoolBackgroundEviction
        // After a connection-open failure on an endpoint, that endpoint
        // is skipped on the next `acquire`'s round-robin pick for this
        // duration. Keeps short outages from causing a thundering herd
        // of doomed connect attempts at one host. The cooldown does
        // not apply when every endpoint is in cooldown (cluster-wide
        // outage): we let one through to detect recovery.
        public let endpointFailureCooldown: TimeAmount
        // Wire-level compression used on Data packets. `.lz4` reduces
        // network bytes at the cost of client CPU; `.uncompressed`
        // is the lowest CPU choice and the right pick when the link
        // is fast enough that protocol overhead dominates.
        public let compression: OutboundCompression
        // Caller-owned. The SDK never shuts this group down; it must
        // outlive the client and any concurrent operations on it. Pass
        // a shared group from your application's NIO bootstrap rather
        // than creating one per Configuration so connections from
        // different clients can share threads.
        public let eventLoopGroup: EventLoopGroup
        public let transportSecurity: TransportSecurity

        public init(
            endpoints: [ClickHouseEndpoint],
            database: String = "default",
            user: String = "default",
            password: String = "",
            clientName: String = "SwiftDX Swift Client",
            clientVersionMajor: UInt64 = 1,
            clientVersionMinor: UInt64 = 0,
            advertisedRevision: UInt64 = 54_479,
            maxConnections: Int = 10,
            maxIdleConnections: Int = 5,
            idleTimeout: TimeAmount = .seconds(60),
            maxLifetime: TimeAmount = .minutes(10),
            connectTimeout: TimeAmount = .seconds(10),
            preflightPingThreshold: PoolPreflightPing = .never,
            acquireTimeout: PoolAcquireTimeout = .failImmediatelyWhenExhausted,
            backgroundEvictionInterval: PoolBackgroundEviction = .onAcquireOnly,
            endpointFailureCooldown: TimeAmount = .seconds(30),
            compression: OutboundCompression = .uncompressed,
            eventLoopGroup: EventLoopGroup,
            transportSecurity: TransportSecurity = .plaintext
        ) {
            self.endpoints = endpoints
            self.database = database
            self.user = user
            self.password = password
            self.clientName = clientName
            self.clientVersionMajor = clientVersionMajor
            self.clientVersionMinor = clientVersionMinor
            self.advertisedRevision = advertisedRevision
            self.maxConnections = maxConnections
            self.maxIdleConnections = maxIdleConnections
            self.idleTimeout = idleTimeout
            self.maxLifetime = maxLifetime
            self.connectTimeout = connectTimeout
            self.preflightPingThreshold = preflightPingThreshold
            self.acquireTimeout = acquireTimeout
            self.backgroundEvictionInterval = backgroundEvictionInterval
            self.endpointFailureCooldown = endpointFailureCooldown
            self.compression = compression
            self.eventLoopGroup = eventLoopGroup
            self.transportSecurity = transportSecurity
        }

        var poolConfiguration: ClickHouseConnectionPool.Configuration {
            let clientHello = ClickHouseClientHelloPacket(
                clientName: clientName,
                versionMajor: clientVersionMajor,
                versionMinor: clientVersionMinor,
                protocolRevision: advertisedRevision,
                defaultDatabase: database,
                username: user,
                password: password
            )
            return .production(
                endpoints: endpoints,
                clientHello: clientHello,
                eventLoopGroup: eventLoopGroup,
                maxConnections: maxConnections,
                maxIdleConnections: maxIdleConnections,
                idleTimeout: idleTimeout,
                maxLifetime: maxLifetime,
                preflightPingThreshold: preflightPingThreshold,
                acquireTimeout: acquireTimeout,
                backgroundEvictionInterval: backgroundEvictionInterval,
                endpointFailureCooldown: endpointFailureCooldown,
                connectTimeout: connectTimeout,
                transportSecurity: transportSecurity,
                compression: compression.wireMethod
            )
        }

    }

}
