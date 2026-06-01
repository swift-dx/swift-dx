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

// Bounded pool of PostgreSQL connections. Each connection serves one request at
// a time, so concurrency comes from running independent callers on separate
// connections. When every connection is leased and the cap is reached, a caller
// parks in a FIFO waiter queue until a connection is released or a slot frees,
// rather than failing; the per-request timeout on the eventual connection still
// bounds the whole operation. Idle connections are evicted once they pass the
// idle timeout or the maximum lifetime, so credential and DNS changes propagate
// across the pool as connections cycle.
actor PostgresConnectionPool {

    struct Configuration: Sendable {

        let endpoints: [PostgresEndpoint]
        let credentials: PostgresCredentials
        let database: PostgresDatabaseName
        let transportSecurity: PostgresTransportSecurity
        let applicationName: String
        let eventLoopGroup: EventLoopGroup
        let connectTimeout: TimeAmount
        let requestTimeout: TimeAmount
        let maxConnections: Int
        let maxIdleConnections: Int
        let idleTimeout: TimeAmount
        let maxLifetime: TimeAmount
        let observability: PostgresObservability
    }

    private struct Entry {

        let connection: PostgresConnection
        let lastReturnedAt: NIODeadline
    }

    private enum Reservation {

        case reuse(PostgresConnection)
        case openSlot
        case mustWait
    }

    private enum Grant: Sendable {

        case connection(PostgresConnection)
        case openSlot
    }

    private struct Waiter {

        let id: UInt64
        let continuation: CheckedContinuation<Grant, Error>
        let timeout: Scheduled<Void>

        func deliver(_ grant: Grant) {
            timeout.cancel()
            continuation.resume(returning: grant)
        }
    }

    private let configuration: Configuration
    private var idle: [Entry] = []
    private var inUseCount = 0
    private var endpointCursor = 0
    private var isShutdown = false
    private var waiters: [Waiter] = []
    private var waiterCounter: UInt64 = 0

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    private var totalConnections: Int {
        idle.count + inUseCount
    }

    func acquire() async throws -> PostgresConnection {
        try ensureUsable()
        let connection = try await grant(reserve())
        configuration.observability.metrics.recordPoolGauges(idle: idle.count, inUse: inUseCount)
        return connection
    }

    private func grant(_ reservation: Reservation) async throws -> PostgresConnection {
        switch reservation {
        case .reuse(let connection): return connection
        case .openSlot: return try await openTracked()
        case .mustWait: return try await awaitGrant()
        }
    }

    private func reserve() -> Reservation {
        if case .found(let connection) = takeHealthyIdle() {
            return .reuse(connection)
        }
        guard totalConnections < configuration.maxConnections else { return .mustWait }
        inUseCount += 1
        return .openSlot
    }

    // Parks the caller until a connection is released or a slot frees, but never
    // forever: an acquire timer fails the waiter with `poolExhausted` if the pool
    // stays saturated past the request timeout. The timer is armed inside the
    // continuation closure so it is paired with the parked continuation under the
    // actor's isolation, and cancelled the moment the waiter is granted.
    private func awaitGrant() async throws -> PostgresConnection {
        let id = nextWaiterID()
        let grant = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Grant, Error>) in
            let timeout = scheduleAcquireTimeout(id)
            waiters.append(Waiter(id: id, continuation: continuation, timeout: timeout))
        }
        return try await fulfill(grant)
    }

    private func nextWaiterID() -> UInt64 {
        waiterCounter += 1
        return waiterCounter
    }

    private func scheduleAcquireTimeout(_ id: UInt64) -> Scheduled<Void> {
        configuration.eventLoopGroup.any().scheduleTask(in: configuration.requestTimeout) {
            Task { await self.timeOutWaiter(id) }
        }
    }

    private func timeOutWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        configuration.observability.metrics.recordPoolTimeout()
        configuration.observability.logger.emitError(.poolExhausted(maxConnections: configuration.maxConnections))
        waiter.continuation.resume(throwing: PostgresError.poolExhausted(maxConnections: configuration.maxConnections))
    }

    private func popFirstWaiter() -> Lookup<Waiter> {
        guard !waiters.isEmpty else { return .notFound }
        return .found(waiters.removeFirst())
    }

    private func fulfill(_ grant: Grant) async throws -> PostgresConnection {
        switch grant {
        case .connection(let connection): return connection
        case .openSlot: return try await openTracked()
        }
    }

    func release(_ connection: PostgresConnection) {
        inUseCount -= 1
        handBack(connection)
        configuration.observability.metrics.recordPoolGauges(idle: idle.count, inUse: inUseCount)
    }

    private func handBack(_ connection: PostgresConnection) {
        guard connection.isActive else { return discardAndOfferSlot(connection) }
        guard case .found(let waiter) = popFirstWaiter() else { return reclaim(connection) }
        inUseCount += 1
        waiter.deliver(.connection(connection))
    }

    private func discardAndOfferSlot(_ connection: PostgresConnection) {
        closeInBackground(connection)
        offerOpenSlotToWaiter()
    }

    private func offerOpenSlotToWaiter() {
        guard case .found(let waiter) = popFirstWaiter() else { return }
        inUseCount += 1
        waiter.deliver(.openSlot)
    }

    func withConnection<Value: Sendable>(_ body: @Sendable (PostgresConnection) async throws -> Value) async throws -> Value {
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
        failWaiters()
        let connections = idle.map(\.connection)
        idle.removeAll(keepingCapacity: false)
        await closeAll(connections)
    }

    private func failWaiters() {
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.timeout.cancel()
            waiter.continuation.resume(throwing: PostgresError.poolShutdown)
        }
    }

    func stats() -> PostgresPoolStats {
        PostgresPoolStats(idleConnections: idle.count, inUseConnections: inUseCount, maxConnections: configuration.maxConnections)
    }

    private func ensureUsable() throws {
        guard !isShutdown else { throw PostgresError.poolShutdown }
        guard !configuration.endpoints.isEmpty else { throw PostgresError.poolHasNoEndpoints }
    }

    // The in-use slot was already reserved by `reserve` or handed over by
    // `offerOpenSlotToWaiter`, so this only opens the connection and, on failure,
    // releases the slot back so a parked waiter can take it.
    private func openTracked() async throws -> PostgresConnection {
        do {
            return try await openConnection()
        } catch {
            releaseSlot()
            throw error
        }
    }

    private func releaseSlot() {
        inUseCount -= 1
        offerOpenSlotToWaiter()
    }

    private func openConnection() async throws -> PostgresConnection {
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

    private func noteConnected(_ endpoint: PostgresEndpoint, start: NIODeadline) {
        configuration.observability.metrics.recordConnectionOpened()
        let elapsed = UInt64(max((NIODeadline.now() - start).nanoseconds, 0))
        configuration.observability.logger.emit(.connected(host: endpoint.host, port: endpoint.port, durationNanos: elapsed))
    }

    private func connect(to endpoint: PostgresEndpoint) async throws -> PostgresConnection {
        try await PostgresConnection.connect(
            endpoint: endpoint,
            credentials: configuration.credentials,
            database: configuration.database,
            applicationName: configuration.applicationName,
            transportSecurity: configuration.transportSecurity,
            eventLoopGroup: configuration.eventLoopGroup,
            connectTimeout: configuration.connectTimeout,
            requestTimeout: configuration.requestTimeout
        )
    }

    private func nextEndpoint() -> PostgresEndpoint {
        let endpoint = configuration.endpoints[endpointCursor % configuration.endpoints.count]
        endpointCursor += 1
        return endpoint
    }

    private func takeHealthyIdle() -> Lookup<PostgresConnection> {
        evictExpiredIdle()
        while let entry = idle.popLast() {
            if entry.connection.isActive { return adopt(entry.connection) }
            closeInBackground(entry.connection)
        }
        return .notFound
    }

    private func adopt(_ connection: PostgresConnection) -> Lookup<PostgresConnection> {
        inUseCount += 1
        return .found(connection)
    }

    private func reclaim(_ connection: PostgresConnection) {
        guard shouldKeepIdle(connection) else { closeInBackground(connection); return }
        idle.append(Entry(connection: connection, lastReturnedAt: NIODeadline.now()))
    }

    private func shouldKeepIdle(_ connection: PostgresConnection) -> Bool {
        guard !isShutdown, connection.isActive else { return false }
        return hasIdleCapacity(for: connection)
    }

    private func hasIdleCapacity(for connection: PostgresConnection) -> Bool {
        guard idle.count < configuration.maxIdleConnections else { return false }
        return !isExpired(connection)
    }

    private func isExpired(_ connection: PostgresConnection) -> Bool {
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

    private func closeInBackground(_ connection: PostgresConnection) {
        Task { await connection.close() }
    }

    private func closeAll(_ connections: [PostgresConnection]) async {
        for connection in connections {
            await connection.close()
        }
    }
}
