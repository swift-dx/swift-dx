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

import DXCore
import NIOCore

// Bounded pool of pipelining Redis connections. A single connection already
// saturates one server with pipelined writes; the pool exists so independent
// concurrent callers run on separate connections (and separate event-loop
// threads) without serialising on each other. When every connection is in use
// and the cap is reached, `acquire` throws `poolExhausted`; the client's
// resilience layer turns that into a brief wait for a connection to free rather
// than a failure. Size `maxConnections` to the expected concurrency.
actor RedisConnectionPool {

    struct Configuration: Sendable {

        let endpoints: [RedisEndpoint]
        let credentials: RedisCredentials
        let database: RedisDatabaseIndex
        let transportSecurity: RedisTransportSecurity
        let eventLoopGroup: EventLoopGroup
        let connectTimeout: TimeAmount
        let requestTimeout: TimeAmount
        let maxConnections: Int
        let maxIdleConnections: Int
        let idleTimeout: TimeAmount
        let maxLifetime: TimeAmount
        let responseDepthLimit: Int
        let maxBulkBytes: Int
        let observability: RedisObservability
    }

    private struct Entry {

        let connection: RedisConnection
        let lastReturnedAt: NIODeadline
    }

    private let configuration: Configuration
    private var idle: [Entry] = []
    private var inUseCount = 0
    private var endpointCursor = 0
    private var isShutdown = false

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    private var totalConnections: Int {
        idle.count + inUseCount
    }

    func acquire() async throws -> RedisConnection {
        try ensureUsable()
        let connection = try await grant()
        configuration.observability.metrics.recordPoolGauges(idle: idle.count, inUse: inUseCount)
        return connection
    }

    private func grant() async throws -> RedisConnection {
        switch takeHealthyIdle() {
        case .found(let connection): return connection
        case .notFound: return try await openOrFail()
        }
    }

    func release(_ connection: RedisConnection) {
        inUseCount -= 1
        reclaim(connection)
        configuration.observability.metrics.recordPoolGauges(idle: idle.count, inUse: inUseCount)
    }

    func withConnection<Value: Sendable>(_ body: @Sendable (RedisConnection) async throws -> Value) async throws -> Value {
        let connection = try await acquire()
        do {
            let value = try await body(connection)
            release(connection)
            return value
        } catch {
            release(connection)
            throw error
        }
    }

    func shutdown() async {
        isShutdown = true
        configuration.observability.logger.emit(.poolShutdown, level: .notice)
        let connections = idle.map(\.connection)
        idle.removeAll(keepingCapacity: false)
        await closeAll(connections)
    }

    func stats() -> RedisPoolStats {
        RedisPoolStats(idleConnections: idle.count, inUseConnections: inUseCount, maxConnections: configuration.maxConnections)
    }

    private func ensureUsable() throws {
        guard !isShutdown else { throw RedisError.poolShutdown }
        guard !configuration.endpoints.isEmpty else { throw RedisError.poolHasNoEndpoints }
    }

    private func openOrFail() async throws -> RedisConnection {
        guard totalConnections < configuration.maxConnections else {
            configuration.observability.metrics.recordPoolTimeout()
            configuration.observability.logger.emitError(.poolExhausted(maxConnections: configuration.maxConnections))
            throw RedisError.poolExhausted(maxConnections: configuration.maxConnections)
        }
        return try await openAndTrack()
    }

    private func openAndTrack() async throws -> RedisConnection {
        inUseCount += 1
        do {
            return try await openConnection()
        } catch {
            inUseCount -= 1
            throw error
        }
    }

    private func openConnection() async throws -> RedisConnection {
        let endpoint = nextEndpoint()
        configuration.observability.logger.emit(.connecting(host: endpoint.host, port: endpoint.port))
        let start = NIODeadline.now()
        do {
            let connection = try await connect(to: endpoint)
            noteConnected(endpoint, start: start)
            return connection
        } catch {
            configuration.observability.logger.emitError(.connectFailed(host: endpoint.host, port: endpoint.port, reason: "\(error)"))
            throw error
        }
    }

    private func noteConnected(_ endpoint: RedisEndpoint, start: NIODeadline) {
        configuration.observability.metrics.recordConnectionOpened()
        let elapsed = UInt64(max((NIODeadline.now() - start).nanoseconds, 0))
        configuration.observability.logger.emit(.connected(host: endpoint.host, port: endpoint.port, durationNanos: elapsed))
    }

    private func connect(to endpoint: RedisEndpoint) async throws -> RedisConnection {
        try await RedisConnection.connect(
            endpoint: endpoint,
            credentials: configuration.credentials,
            database: configuration.database,
            transportSecurity: configuration.transportSecurity,
            eventLoopGroup: configuration.eventLoopGroup,
            connectTimeout: configuration.connectTimeout,
            requestTimeout: configuration.requestTimeout,
            responseDepthLimit: configuration.responseDepthLimit,
            maxBulkBytes: configuration.maxBulkBytes
        )
    }

    private func nextEndpoint() -> RedisEndpoint {
        let endpoint = configuration.endpoints[endpointCursor % configuration.endpoints.count]
        endpointCursor += 1
        return endpoint
    }

    private func takeHealthyIdle() -> Lookup<RedisConnection> {
        evictExpiredIdle()
        while let entry = idle.popLast() {
            if entry.connection.isActive { return adopt(entry.connection) }
            closeInBackground(entry.connection)
        }
        return .notFound
    }

    private func adopt(_ connection: RedisConnection) -> Lookup<RedisConnection> {
        inUseCount += 1
        return .found(connection)
    }

    private func reclaim(_ connection: RedisConnection) {
        guard shouldKeepIdle(connection) else { closeInBackground(connection); return }
        idle.append(Entry(connection: connection, lastReturnedAt: NIODeadline.now()))
    }

    private func shouldKeepIdle(_ connection: RedisConnection) -> Bool {
        guard isAcceptingIdle, connection.isActive else { return false }
        return hasIdleCapacity(for: connection)
    }

    private var isAcceptingIdle: Bool {
        !isShutdown
    }

    private func hasIdleCapacity(for connection: RedisConnection) -> Bool {
        guard idle.count < configuration.maxIdleConnections else { return false }
        return !isExpired(connection)
    }

    private func isExpired(_ connection: RedisConnection) -> Bool {
        NIODeadline.now() >= connection.openedAt + configuration.maxLifetime
    }

    private func evictExpiredIdle() {
        let now = NIODeadline.now()
        var survivors: [Entry] = []
        survivors.reserveCapacity(idle.count)
        for entry in idle {
            routeEviction(entry, now: now, into: &survivors)
        }
        idle = survivors
    }

    private func routeEviction(_ entry: Entry, now: NIODeadline, into survivors: inout [Entry]) {
        guard keepDuringEviction(entry, now: now) else { closeInBackground(entry.connection); return }
        survivors.append(entry)
    }

    private func keepDuringEviction(_ entry: Entry, now: NIODeadline) -> Bool {
        guard entry.connection.isActive else { return false }
        return now < entry.connection.openedAt + configuration.maxLifetime && now < entry.lastReturnedAt + configuration.idleTimeout
    }

    private func closeInBackground(_ connection: RedisConnection) {
        Task { await connection.close() }
    }

    private func closeAll(_ connections: [RedisConnection]) async {
        for connection in connections {
            await connection.close()
        }
    }
}
