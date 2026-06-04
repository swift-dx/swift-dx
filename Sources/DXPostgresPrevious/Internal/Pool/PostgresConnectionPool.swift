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
import NIOConcurrencyHelpers
import NIOCore

// Bounded pool of PostgreSQL connections. Each connection serves one request at
// a time, so concurrency comes from running independent callers on separate
// connections. When every connection is leased and the cap is reached, a caller
// parks in a FIFO waiter queue until a connection is released or a slot frees,
// rather than failing; the per-request timeout on the eventual connection still
// bounds the whole operation. Idle connections are evicted once they pass the
// idle timeout or the maximum lifetime, so credential and DNS changes propagate
// across the pool as connections cycle.
//
// State lives behind one lock rather than an actor: every acquire and release
// decision is a short synchronous critical section with no suspension point, so
// a lock serializes them without funnelling thousands of contending callers
// through a single actor executor. The lock only guards the bookkeeping; opening
// a connection and resuming a parked waiter both happen after the lock is
// released, returned from the critical section as an explicit deferred action so
// a continuation never resumes while the lock is held.
final class PostgresConnectionPool: Sendable {

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

    // `@unchecked Sendable` is sound because `fulfilled` is only ever read or
    // written inside the pool's lock, the single place all waiter state changes.
    private final class Waiter: @unchecked Sendable {

        let id: UInt64
        let continuation: CheckedContinuation<Grant, Error>
        let timeout: Scheduled<Void>
        var fulfilled: Bool

        init(id: UInt64, continuation: CheckedContinuation<Grant, Error>, timeout: Scheduled<Void>) {
            self.id = id
            self.continuation = continuation
            self.timeout = timeout
            self.fulfilled = false
        }
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

    private enum ReleaseAction {

        case keepIdle
        case close(PostgresConnection)
        case deliverConnection(PostgresConnection, Waiter)
        case closeAndDeliverSlot(PostgresConnection, Waiter)
        case deliverSlot(Waiter)
    }

    private struct State {

        var idle: [Entry] = []
        var inUseCount = 0
        var endpointCursor = 0
        var isShutdown = false
        var waiters: [Waiter] = []
        var waitHead = 0
        var waiterCounter: UInt64 = 0

        var totalConnections: Int {
            idle.count + inUseCount
        }
    }

    private let configuration: Configuration
    private let state = NIOLockedValueBox(State())

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func acquire() async throws -> PostgresConnection {
        var dead: [PostgresConnection] = []
        let reservation = try state.withLockedValue { state -> Reservation in
            try ensureUsable(state)
            return reserve(&state, dead: &dead)
        }
        closeInBackground(dead)
        let connection = try await grant(reservation)
        recordGauges()
        return connection
    }

    private func ensureUsable(_ state: State) throws {
        guard !state.isShutdown else { throw PostgresError.poolShutdown }
        guard !configuration.endpoints.isEmpty else { throw PostgresError.poolHasNoEndpoints }
    }

    private func reserve(_ state: inout State, dead: inout [PostgresConnection]) -> Reservation {
        if case .found(let connection) = takeHealthyIdle(&state, dead: &dead) {
            return .reuse(connection)
        }
        guard state.totalConnections < configuration.maxConnections else { return .mustWait }
        state.inUseCount += 1
        return .openSlot
    }

    private func grant(_ reservation: Reservation) async throws -> PostgresConnection {
        switch reservation {
        case .reuse(let connection): return connection
        case .openSlot: return try await openTracked()
        case .mustWait: return try await awaitGrant()
        }
    }

    // Parks the caller until a connection is released or a slot frees, but never
    // forever: an acquire timer fails the waiter with `poolExhausted` if the pool
    // stays saturated past the request timeout. The waiter, its id and its timer
    // are registered together under the lock so a timeout that fires immediately
    // still finds the waiter to remove, and the timer is cancelled the moment the
    // waiter is granted.
    private func awaitGrant() async throws -> PostgresConnection {
        let grant = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Grant, Error>) in
            state.withLockedValue { state in
                state.waiterCounter += 1
                let id = state.waiterCounter
                let timeout = configuration.eventLoopGroup.any().scheduleTask(in: configuration.requestTimeout) {
                    self.timeOutWaiter(id)
                }
                state.waiters.append(Waiter(id: id, continuation: continuation, timeout: timeout))
            }
        }
        return try await fulfill(grant)
    }

    private func timeOutWaiter(_ id: UInt64) {
        let lookup = state.withLockedValue { state -> Lookup<Waiter> in markTimedOut(&state, id) }
        guard case .found(let waiter) = lookup else { return }
        configuration.observability.metrics.recordPoolTimeout()
        configuration.observability.logger.emitError(.poolExhausted(maxConnections: configuration.maxConnections))
        waiter.continuation.resume(throwing: PostgresError.poolExhausted(maxConnections: configuration.maxConnections))
    }

    // Marks a timed-out waiter fulfilled in place rather than removing it, leaving
    // a tombstone the head cursor skips. A waiter already granted (fulfilled) is
    // left to the grant, so it resumes exactly once.
    private func markTimedOut(_ state: inout State, _ id: UInt64) -> Lookup<Waiter> {
        guard let index = state.waiters[state.waitHead...].firstIndex(where: { $0.id == id && !$0.fulfilled }) else { return .notFound }
        let waiter = state.waiters[index]
        waiter.fulfilled = true
        return .found(waiter)
    }

    private func fulfill(_ grant: Grant) async throws -> PostgresConnection {
        switch grant {
        case .connection(let connection): return connection
        case .openSlot: return try await openTracked()
        }
    }

    func release(_ connection: PostgresConnection) {
        let action = state.withLockedValue { state -> ReleaseAction in
            state.inUseCount -= 1
            return handBack(&state, connection)
        }
        perform(action)
        recordGauges()
    }

    private func handBack(_ state: inout State, _ connection: PostgresConnection) -> ReleaseAction {
        guard connection.isActive else { return discardAndOfferSlot(&state, connection) }
        guard case .found(let waiter) = popFirstWaiter(&state) else { return reclaim(&state, connection) }
        state.inUseCount += 1
        return .deliverConnection(connection, waiter)
    }

    private func discardAndOfferSlot(_ state: inout State, _ connection: PostgresConnection) -> ReleaseAction {
        guard case .found(let waiter) = popFirstWaiter(&state) else { return .close(connection) }
        state.inUseCount += 1
        return .closeAndDeliverSlot(connection, waiter)
    }

    private func reclaim(_ state: inout State, _ connection: PostgresConnection) -> ReleaseAction {
        guard shouldKeepIdle(&state, connection) else { return .close(connection) }
        state.idle.append(Entry(connection: connection, lastReturnedAt: NIODeadline.now()))
        return .keepIdle
    }

    // Dequeues the oldest still-pending waiter in amortized O(1): a head cursor
    // advances over the queue and skips waiters already marked fulfilled by a
    // timeout, so neither granting nor timing out shifts the array. The consumed
    // prefix is dropped once it grows past half the buffer, keeping the queue
    // bounded under a timeout storm.
    private func popFirstWaiter(_ state: inout State) -> Lookup<Waiter> {
        while state.waitHead < state.waiters.count {
            let waiter = state.waiters[state.waitHead]
            state.waitHead += 1
            guard !waiter.fulfilled else { continue }
            waiter.fulfilled = true
            compactWaiters(&state)
            return .found(waiter)
        }
        state.waiters.removeAll(keepingCapacity: true)
        state.waitHead = 0
        return .notFound
    }

    private func compactWaiters(_ state: inout State) {
        guard state.waitHead >= 64, state.waitHead * 2 >= state.waiters.count else { return }
        state.waiters.removeFirst(state.waitHead)
        state.waitHead = 0
    }

    // Resumes any granted waiter and closes any discarded connection after the
    // lock is released, so a continuation never runs inside the critical section.
    private func perform(_ action: ReleaseAction) {
        switch action {
        case .keepIdle: return
        case .close(let connection): closeInBackground(connection)
        case .deliverConnection(let connection, let waiter): deliver(waiter, .connection(connection))
        case .closeAndDeliverSlot(let connection, let waiter): closeInBackground(connection); deliver(waiter, .openSlot)
        case .deliverSlot(let waiter): deliver(waiter, .openSlot)
        }
    }

    private func deliver(_ waiter: Waiter, _ grant: Grant) {
        waiter.timeout.cancel()
        waiter.continuation.resume(returning: grant)
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
        let drained = state.withLockedValue { state -> (waiters: [Waiter], connections: [PostgresConnection]) in
            state.isShutdown = true
            let waiters = state.waiters[state.waitHead...].filter { !$0.fulfilled }
            state.waiters.removeAll(keepingCapacity: false)
            state.waitHead = 0
            let connections = state.idle.map(\.connection)
            state.idle.removeAll(keepingCapacity: false)
            return (waiters, connections)
        }
        configuration.observability.logger.emit(.poolShutdown, level: .notice)
        failWaiters(drained.waiters)
        await closeAll(drained.connections)
    }

    private func failWaiters(_ waiters: [Waiter]) {
        for waiter in waiters {
            waiter.fulfilled = true
            waiter.timeout.cancel()
            waiter.continuation.resume(throwing: PostgresError.poolShutdown)
        }
    }

    func stats() -> PostgresPoolStats {
        state.withLockedValue { state in
            PostgresPoolStats(idleConnections: state.idle.count, inUseConnections: state.inUseCount, maxConnections: configuration.maxConnections)
        }
    }

    private func recordGauges() {
        let snapshot = state.withLockedValue { state in (idle: state.idle.count, inUse: state.inUseCount) }
        configuration.observability.metrics.recordPoolGauges(idle: snapshot.idle, inUse: snapshot.inUse)
    }

    // The in-use slot was already reserved by `reserve` or handed over by a
    // released connection, so this only opens the connection and, on failure,
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
        let action = state.withLockedValue { state -> ReleaseAction in
            state.inUseCount -= 1
            return offerOpenSlotToWaiter(&state)
        }
        perform(action)
    }

    private func offerOpenSlotToWaiter(_ state: inout State) -> ReleaseAction {
        guard case .found(let waiter) = popFirstWaiter(&state) else { return .keepIdle }
        state.inUseCount += 1
        return .deliverSlot(waiter)
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
        state.withLockedValue { state in
            let endpoint = configuration.endpoints[state.endpointCursor % configuration.endpoints.count]
            state.endpointCursor += 1
            return endpoint
        }
    }

    private func takeHealthyIdle(_ state: inout State, dead: inout [PostgresConnection]) -> Lookup<PostgresConnection> {
        evictExpiredIdle(&state, dead: &dead)
        while let entry = state.idle.popLast() {
            if entry.connection.isActive { state.inUseCount += 1; return .found(entry.connection) }
            dead.append(entry.connection)
        }
        return .notFound
    }

    private func shouldKeepIdle(_ state: inout State, _ connection: PostgresConnection) -> Bool {
        guard !state.isShutdown, connection.isActive else { return false }
        return hasIdleCapacity(&state, connection)
    }

    private func hasIdleCapacity(_ state: inout State, _ connection: PostgresConnection) -> Bool {
        guard state.idle.count < configuration.maxIdleConnections else { return false }
        return !isExpired(connection)
    }

    private func isExpired(_ connection: PostgresConnection) -> Bool {
        NIODeadline.now() >= connection.openedAt + configuration.maxLifetime
    }

    private func evictExpiredIdle(_ state: inout State, dead: inout [PostgresConnection]) {
        let now = NIODeadline.now()
        var survivors: [Entry] = []
        survivors.reserveCapacity(state.idle.count)
        for entry in state.idle {
            routeEviction(entry, now: now, into: &survivors, dead: &dead)
        }
        state.idle = survivors
    }

    private func routeEviction(_ entry: Entry, now: NIODeadline, into survivors: inout [Entry], dead: inout [PostgresConnection]) {
        guard keepDuringEviction(entry, now: now) else { dead.append(entry.connection); return }
        survivors.append(entry)
    }

    private func keepDuringEviction(_ entry: Entry, now: NIODeadline) -> Bool {
        guard entry.connection.isActive else { return false }
        return now < entry.connection.openedAt + configuration.maxLifetime && now < entry.lastReturnedAt + configuration.idleTimeout
    }

    private func closeInBackground(_ connection: PostgresConnection) {
        Task { await connection.close() }
    }

    private func closeInBackground(_ connections: [PostgresConnection]) {
        guard !connections.isEmpty else { return }
        Task {
            for connection in connections {
                await connection.close()
            }
        }
    }

    private func closeAll(_ connections: [PostgresConnection]) async {
        for connection in connections {
            await connection.close()
        }
    }
}
