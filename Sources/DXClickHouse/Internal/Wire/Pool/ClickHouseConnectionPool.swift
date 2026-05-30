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

import Foundation
import NIOConcurrencyHelpers
import NIOCore

// Bounded actor-isolated connection pool with multi-endpoint round-robin,
// failover, idle eviction, and max-lifetime tracking.
//
// Per-connection metadata (openedAt for max-lifetime, returnedAt for
// idle-timeout) lives in actor-private maps keyed by ObjectIdentifier
// of the connection rather than on the connection itself, so the
// connection stays a clean transport wrapper and pool concerns live
// on the pool.
//
// `withConnection { ... }` is the safe API: auto-releases on both
// success and throw paths. `acquire`/`release` is the explicit-lifetime
// alternative for advanced cases.
//
// Eviction runs on `acquire`, not on a background timer — simpler,
// deterministic, no orphan task lifecycle. Stale-but-still-pooled
// connections persist until the next acquire; in practice that's
// seconds, and the simplicity wins over a background sweep.
actor ClickHouseConnectionPool {

    struct Configuration: Sendable {

        let endpoints: [ClickHouseEndpoint]
        let maxConnections: Int
        let maxIdleConnections: Int
        let idleTimeout: TimeAmount
        let maxLifetime: TimeAmount
        let preflightPingThreshold: ClickHouseClient.PoolPreflightPing
        let acquireTimeout: ClickHouseClient.PoolAcquireTimeout
        let backgroundEvictionInterval: ClickHouseClient.PoolBackgroundEviction
        let endpointFailureCooldown: TimeAmount
        let connectionFactory: @Sendable (ClickHouseEndpoint) async throws -> ClickHouseConnection
        let nowProvider: @Sendable () -> NIODeadline

        init(
            endpoints: [ClickHouseEndpoint],
            maxConnections: Int = 10,
            maxIdleConnections: Int = 5,
            idleTimeout: TimeAmount = .seconds(60),
            maxLifetime: TimeAmount = .minutes(10),
            preflightPingThreshold: ClickHouseClient.PoolPreflightPing = .never,
            acquireTimeout: ClickHouseClient.PoolAcquireTimeout = .failImmediatelyWhenExhausted,
            backgroundEvictionInterval: ClickHouseClient.PoolBackgroundEviction = .onAcquireOnly,
            endpointFailureCooldown: TimeAmount = .seconds(30),
            connectionFactory: @escaping @Sendable (ClickHouseEndpoint) async throws -> ClickHouseConnection,
            nowProvider: @escaping @Sendable () -> NIODeadline = { .now() }
        ) {
            self.endpoints = endpoints
            self.maxConnections = maxConnections
            self.maxIdleConnections = maxIdleConnections
            self.idleTimeout = idleTimeout
            self.maxLifetime = maxLifetime
            self.preflightPingThreshold = preflightPingThreshold
            self.acquireTimeout = acquireTimeout
            self.backgroundEvictionInterval = backgroundEvictionInterval
            self.endpointFailureCooldown = endpointFailureCooldown
            self.connectionFactory = connectionFactory
            self.nowProvider = nowProvider
        }

        static func production(
            endpoints: [ClickHouseEndpoint],
            clientHello: ClickHouseClientHelloPacket,
            eventLoopGroup: EventLoopGroup,
            maxConnections: Int = 10,
            maxIdleConnections: Int = 5,
            idleTimeout: TimeAmount = .seconds(60),
            maxLifetime: TimeAmount = .minutes(10),
            preflightPingThreshold: ClickHouseClient.PoolPreflightPing = .never,
            acquireTimeout: ClickHouseClient.PoolAcquireTimeout = .failImmediatelyWhenExhausted,
            backgroundEvictionInterval: ClickHouseClient.PoolBackgroundEviction = .onAcquireOnly,
            endpointFailureCooldown: TimeAmount = .seconds(30),
            connectTimeout: TimeAmount = .seconds(10),
            transportSecurity: ClickHouseClient.TransportSecurity = .plaintext,
            compression: ClickHouseCompressionMethod = .uncompressed
        ) -> Self {
            Self(
                endpoints: endpoints,
                maxConnections: maxConnections,
                maxIdleConnections: maxIdleConnections,
                idleTimeout: idleTimeout,
                maxLifetime: maxLifetime,
                preflightPingThreshold: preflightPingThreshold,
                acquireTimeout: acquireTimeout,
                backgroundEvictionInterval: backgroundEvictionInterval,
                endpointFailureCooldown: endpointFailureCooldown,
                connectionFactory: { endpoint in
                    try await ClickHouseConnection.connect(
                        host: endpoint.host,
                        port: endpoint.port,
                        clientHello: clientHello,
                        eventLoopGroup: eventLoopGroup,
                        connectTimeout: connectTimeout,
                        transportSecurity: transportSecurity,
                        compression: compression
                    )
                }
            )
        }

    }

    private struct PooledEntry {

        let connection: ClickHouseConnection
        let openedAt: NIODeadline
        var returnedAt: NIODeadline

    }

    private struct ActiveEntry {

        let connection: ClickHouseConnection
        let openedAt: NIODeadline

    }

    private struct WaiterID: Hashable, Equatable, Sendable {

        let value = UUID()

    }

    private enum EvictionTaskState {

        case notStarted
        case running(Task<Void, Never>)

    }

    private struct Waiter {

        let id: WaiterID
        let continuation: CheckedContinuation<ClickHouseConnection, Error>

    }

    private enum WaiterPopOutcome {

        case popped(Waiter)
        case notPresent

    }

    let configuration: Configuration
    private var idle: [PooledEntry] = []
    private var active: [ObjectIdentifier: ActiveEntry] = [:]
    // Slots reserved for in-flight opens that haven't yet returned a
    // connection. Counted alongside `active.count` against
    // `maxConnections` so two concurrent acquires can't both pass the
    // capacity check while suspended on the same connect await.
    private var openingCount: Int = 0
    private struct WaiterState {

        var waiters: [Waiter] = []
        // IDs whose cancel handler fired BEFORE the body of
        // `withCheckedThrowingContinuation` had a chance to append
        // the waiter (Swift's Concurrency lets onCancel and body
        // run concurrently when the awaiting Task was already
        // cancelled). The body checks this set under the same lock
        // and resumes the continuation immediately with
        // CancellationError if its id is here. Per Swift docs,
        // onCancel doesn't fire after body completes, so a stale
        // entry never enters this set after the waiter has been
        // resolved by release/timeout — the set is bounded.
        var cancelledWaiterIDs: Set<WaiterID> = []

    }

    // Waiter queue + cancel-pending set live in a NIOLockedValueBox
    // rather than under actor isolation. This lets the suspension path
    // append the waiter SYNCHRONOUSLY inside
    // `withCheckedThrowingContinuation`'s body (which is non-async and
    // therefore can't call actor-isolated methods). The previous design
    // used a `Task { ... }` hop to bridge the body into the actor; the
    // spawn-vs-actor-reentry window made `release()` race with the
    // enqueue and orphan waiters. With the queue under a lock, the
    // append is atomic with the suspension and no Task hop exists.
    //
    // The lock covers ONLY the waiter queue; other pool state (idle,
    // active, openingCount, ...) stays under actor isolation. Actor
    // methods access the queue via the lock; the cancel handler closure
    // (non-actor) accesses it the same way. Both are synchronous.
    private let waiterState: NIOLockedValueBox<WaiterState> = NIOLockedValueBox(WaiterState())
    private var endpointCursor: Int = 0
    private var endpointFailures: [Int: NIODeadline] = [:]
    private var evictionTask: EvictionTaskState = .notStarted
    private var totalConnectionsOpened: Int = 0
    // Set once `shutdown()` finishes. After this point the pool is
    // terminal: acquire throws immediately and release closes its
    // argument instead of returning it to idle. Without this flag the
    // pool is "undead" — shutdown clears state but the next acquire
    // restarts the eviction task and opens fresh connections, leaking
    // the lifecycle contract that callers reasonably expect.
    private var isShutdown: Bool = false

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    // Lazy spawn: the actor init can't safely capture self in a Task.
    // First acquire triggers the background eviction loop if configured.
    // Subsequent acquires are no-ops because the task is already running.
    private func ensureBackgroundEvictionStarted() {
        guard case .notStarted = evictionTask else { return }
        guard case .every(let interval) = configuration.backgroundEvictionInterval else { return }
        let intervalNanos = UInt64(max(0, interval.nanoseconds))
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanos)
                if Task.isCancelled { break }
                guard let pool = self else { break }
                await pool.evictExpired()
            }
        }
        evictionTask = .running(task)
    }

    var idleCount: Int { idle.count }
    var activeCount: Int { active.count }
    var waiterCount: Int { waiterState.withLockedValue { $0.waiters.count } }
    // Diagnostic accessor for the pending-cancellation set. Used by
    // tests to verify the set drains under load (every insert by an
    // early-cancelling task is consumed by the eventually-running
    // continuation body). At quiescence this should be 0; non-zero
    // values indicate a bookkeeping leak.
    var pendingCancellationCount: Int { waiterState.withLockedValue { $0.cancelledWaiterIDs.count } }

    func stats() -> ClickHouseConnectionPoolStats {
        let now = configuration.nowProvider()
        let cooldown = configuration.endpointFailureCooldown
        let endpointHealth = configuration.endpoints.enumerated().map { index, endpoint -> ClickHouseEndpointHealth in
            let isCoolingDown: Bool
            if let failedAt = endpointFailures[index] {
                isCoolingDown = now < failedAt + cooldown
            } else {
                isCoolingDown = false
            }
            return ClickHouseEndpointHealth(
                endpoint: endpoint,
                status: isCoolingDown ? .coolingDown : .healthy
            )
        }
        let unhealthy = endpointHealth.filter { $0.status == .coolingDown }.count
        return ClickHouseConnectionPoolStats(
            idleCount: idle.count,
            activeCount: active.count,
            waiterCount: waiterState.withLockedValue { $0.waiters.count },
            totalConnectionsOpened: totalConnectionsOpened,
            unhealthyEndpointCount: unhealthy,
            configuredMaxConnections: configuration.maxConnections,
            configuredMaxIdleConnections: configuration.maxIdleConnections,
            endpointHealth: endpointHealth
        )
    }

    func effectiveWarmupCount(requested: Int) -> Int {
        max(0, min(requested, configuration.maxConnections, configuration.maxIdleConnections))
    }

    func acquire() async throws -> ClickHouseConnection {
        if isShutdown {
            throw ClickHouseError.poolShutdown
        }
        ensureBackgroundEvictionStarted()
        evictExpired()
        return try await acquireRecycledOrNew()
    }

    private enum AcquireAttemptOutcome {

        case acquired(ClickHouseConnection)
        case unavailable

    }

    private func acquireRecycledOrNew() async throws -> ClickHouseConnection {
        switch try await acquireFromIdle() {
        case .acquired(let connection): return connection
        case .unavailable: break
        }
        switch try await acquireNewlyOpened() {
        case .acquired(let connection): return connection
        case .unavailable: break
        }
        return try await acquireFromWaitQueue()
    }

    private func acquireFromIdle() async throws -> AcquireAttemptOutcome {
        while let entry = idle.popLast() {
            switch try await adoptIdleEntry(entry) {
            case .acquired(let connection): return .acquired(connection)
            case .unavailable: continue
            }
        }
        return .unavailable
    }

    private func adoptIdleEntry(_ entry: PooledEntry) async throws -> AcquireAttemptOutcome {
        guard await isViable(entry: entry) else {
            let stale = entry.connection
            Task { try? await stale.close() }
            return .unavailable
        }
        if isShutdown {
            let stale = entry.connection
            Task { try? await stale.close() }
            throw ClickHouseError.poolShutdown
        }
        active[ObjectIdentifier(entry.connection)] = ActiveEntry(connection: entry.connection, openedAt: entry.openedAt)
        return .acquired(entry.connection)
    }

    private func acquireNewlyOpened() async throws -> AcquireAttemptOutcome {
        guard active.count + openingCount < configuration.maxConnections else { return .unavailable }
        let connection = try await openConnectionReservingSlot()
        return .acquired(try adoptOpenedConnection(connection))
    }

    private func openConnectionReservingSlot() async throws -> ClickHouseConnection {
        openingCount += 1
        do {
            let connection = try await openWithFailover()
            openingCount -= 1
            return connection
        } catch {
            openingCount -= 1
            throw error
        }
    }

    private func adoptOpenedConnection(_ connection: ClickHouseConnection) throws -> ClickHouseConnection {
        if isShutdown {
            Task { try? await connection.close() }
            throw ClickHouseError.poolShutdown
        }
        totalConnectionsOpened += 1
        active[ObjectIdentifier(connection)] = ActiveEntry(connection: connection, openedAt: configuration.nowProvider())
        return connection
    }

    private func acquireFromWaitQueue() async throws -> ClickHouseConnection {
        guard case .waitUpTo(let timeout) = configuration.acquireTimeout else {
            throw ClickHouseError.poolExhausted(maxConnections: configuration.maxConnections)
        }
        return try await suspendForRelease(timeout: timeout)
    }

    private func suspendForRelease(timeout: TimeAmount) async throws -> ClickHouseConnection {
        let id = WaiterID()
        // Capture immutable refs for the non-actor cancel handler and
        // the timeout Task. Actor isolation doesn't reach into either.
        let state = self.waiterState
        let timeoutNs = timeout.nanoseconds
        let maxConn = configuration.maxConnections
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ClickHouseConnection, Error>) in
                let waiter = Waiter(id: id, continuation: continuation)
                // Atomic with the lock: if the cancel handler already
                // fired (Task was cancelled before the body got here),
                // the id is in `cancelledWaiterIDs`. Resume cancelled.
                // Otherwise append the waiter so a concurrent release
                // or timeout can pop it.
                let resumeWithCancellation: Bool = state.withLockedValue { state in
                    if state.cancelledWaiterIDs.remove(id) != nil {
                        return true
                    }
                    state.waiters.append(waiter)
                    return false
                }
                if resumeWithCancellation {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                // Schedule the deadline. The timeout Task is fire-and-
                // forget; its only job is to resume the continuation
                // with `poolWaitTimeout` if no other path resolved the
                // waiter first. Lookup-by-id under the lock; if the
                // waiter is gone (resolved by release/cancel), no-op.
                let nanos = UInt64(max(0, timeout.nanoseconds))
                Task {
                    try? await Task.sleep(nanoseconds: nanos)
                    let timedOut = state.withLockedValue { state -> WaiterPopOutcome in
                        guard let index = state.waiters.firstIndex(where: { $0.id == id }) else {
                            return .notPresent
                        }
                        return .popped(state.waiters.remove(at: index))
                    }
                    if case .popped(let waiter) = timedOut {
                        waiter.continuation.resume(throwing: ClickHouseError.poolWaitTimeout(
                            timeoutNanoseconds: timeoutNs,
                            maxConnections: maxConn
                        ))
                    }
                }
            }
        } onCancel: {
            // Cancel handler runs synchronously when the awaiting Task
            // is cancelled. If the body has already appended the
            // waiter, pop and resume with CancellationError. If the
            // body hasn't reached its append yet (cancel fires
            // concurrently with body when the parent Task was already
            // cancelled before withTaskCancellationHandler ran),
            // record the id so the body's atomic check sees it.
            let cancelled = state.withLockedValue { state -> WaiterPopOutcome in
                if let index = state.waiters.firstIndex(where: { $0.id == id }) {
                    return .popped(state.waiters.remove(at: index))
                }
                state.cancelledWaiterIDs.insert(id)
                return .notPresent
            }
            if case .popped(let waiter) = cancelled {
                waiter.continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func popPendingWaiter() -> WaiterPopOutcome {
        waiterState.withLockedValue { state in
            state.waiters.isEmpty ? .notPresent : .popped(state.waiters.removeFirst())
        }
    }

    private func isViable(entry: PooledEntry) async -> Bool {
        guard entry.connection.isActive else { return false }
        return await isViablePerPreflight(entry: entry)
    }

    private func isViablePerPreflight(entry: PooledEntry) async -> Bool {
        guard case .afterIdleFor(let threshold) = configuration.preflightPingThreshold else { return true }
        if !preflightThresholdExceeded(entry: entry, threshold: threshold) { return true }
        return await pingSucceeds(entry: entry)
    }

    private func preflightThresholdExceeded(entry: PooledEntry, threshold: TimeAmount) -> Bool {
        let now = configuration.nowProvider()
        return now >= entry.returnedAt + threshold
    }

    private func pingSucceeds(entry: PooledEntry) async -> Bool {
        do {
            try await entry.connection.ping()
            return true
        } catch {
            return false
        }
    }

    func release(_ connection: ClickHouseConnection) {
        let identifier = ObjectIdentifier(connection)
        guard let entry = active.removeValue(forKey: identifier) else { return }
        guard releasePreFlightAllowsPark(connection: connection) else { return }
        finishRelease(connection: connection, identifier: identifier, entry: entry)
    }

    private func finishRelease(connection: ClickHouseConnection, identifier: ObjectIdentifier, entry: ActiveEntry) {
        let now = configuration.nowProvider()
        let lifetimeExceeded = now >= entry.openedAt + configuration.maxLifetime
        if handOffToWaiter(connection: connection, identifier: identifier, openedAt: entry.openedAt, lifetimeExceeded: lifetimeExceeded) {
            return
        }
        parkOrCloseConnection(connection: connection, openedAt: entry.openedAt, now: now, lifetimeExceeded: lifetimeExceeded)
    }

    private func releasePreFlightAllowsPark(connection: ClickHouseConnection) -> Bool {
        if isShutdown {
            Task { try? await connection.close() }
            return false
        }
        return connection.isActive
    }

    private func handOffToWaiter(connection: ClickHouseConnection, identifier: ObjectIdentifier, openedAt: NIODeadline, lifetimeExceeded: Bool) -> Bool {
        guard !lifetimeExceeded else { return false }
        switch popPendingWaiter() {
        case .notPresent:
            return false
        case .popped(let waiter):
            active[identifier] = ActiveEntry(connection: connection, openedAt: openedAt)
            waiter.continuation.resume(returning: connection)
            return true
        }
    }

    private func parkOrCloseConnection(connection: ClickHouseConnection, openedAt: NIODeadline, now: NIODeadline, lifetimeExceeded: Bool) {
        if lifetimeExceeded {
            Task { try? await connection.close() }
            return
        }
        if idle.count >= configuration.maxIdleConnections {
            Task { try? await connection.close() }
            return
        }
        idle.append(PooledEntry(connection: connection, openedAt: openedAt, returnedAt: now))
    }

    func withConnection<T: Sendable>(_ body: @Sendable (ClickHouseConnection) async throws -> T) async throws -> T {
        let connection = try await acquire()
        do {
            let result = try await body(connection)
            release(connection)
            return result
        } catch {
            release(connection)
            throw error
        }
    }

    func shutdown() async {
        isShutdown = true
        cancelEvictionTask()
        await closeAllPooledConnections()
        idle.removeAll()
        active.removeAll()
        resumePendingWaitersWithShutdown()
    }

    private func cancelEvictionTask() {
        if case .running(let task) = evictionTask {
            task.cancel()
        }
        evictionTask = .notStarted
    }

    private func closeAllPooledConnections() async {
        for entry in idle {
            try? await entry.connection.close()
        }
        for entry in active.values {
            try? await entry.connection.close()
        }
    }

    private func resumePendingWaitersWithShutdown() {
        let pending = waiterState.withLockedValue { state -> [Waiter] in
            let snapshot = state.waiters
            state.waiters.removeAll()
            state.cancelledWaiterIDs.removeAll()
            return snapshot
        }
        for waiter in pending {
            waiter.continuation.resume(throwing: ClickHouseError.poolShutdown)
        }
    }

    private func evictExpired() {
        let now = configuration.nowProvider()
        idle.removeAll { entry in
            // A connection whose server hung up between release and
            // the next acquire is dead idle weight: isViable would
            // reject it on the next acquire, but evicting it eagerly
            // here keeps the idle list honest about real capacity.
            // No close needed: the underlying channel is already
            // inactive by definition.
            if !entry.connection.isActive {
                return true
            }
            let lifetimeExpired = now >= entry.openedAt + configuration.maxLifetime
            let idleExpired = now >= entry.returnedAt + configuration.idleTimeout
            if lifetimeExpired || idleExpired {
                let connection = entry.connection
                Task { try? await connection.close() }
                return true
            }
            return false
        }
    }

    private func openWithFailover() async throws -> ClickHouseConnection {
        guard !configuration.endpoints.isEmpty else {
            throw ClickHouseError.poolHasNoEndpoints
        }
        var lastError: String = ""
        switch try await iterateFailoverEndpoints(lastError: &lastError) {
        case .opened(let connection):
            return connection
        case .exhausted:
            throw ClickHouseError.allPoolEndpointsFailed(lastError: lastError)
        }
    }

    private enum FailoverIterationOutcome {

        case opened(ClickHouseConnection)
        case exhausted

    }

    private enum EndpointAttemptOutcome {

        case opened(ClickHouseConnection)
        case failed
        case alreadyTried

    }

    private func iterateFailoverEndpoints(lastError: inout String) async throws -> FailoverIterationOutcome {
        var triedIndexes: Set<Int> = []
        for _ in 0..<configuration.endpoints.count {
            switch try await tryNextEndpoint(triedIndexes: &triedIndexes, lastError: &lastError) {
            case .opened(let connection):
                return .opened(connection)
            case .failed, .alreadyTried:
                continue
            }
        }
        return .exhausted
    }

    private func tryNextEndpoint(triedIndexes: inout Set<Int>, lastError: inout String) async throws -> EndpointAttemptOutcome {
        let pick = nextEndpoint()
        guard triedIndexes.insert(pick.index).inserted else { return .alreadyTried }
        do {
            let connection = try await configuration.connectionFactory(pick.endpoint)
            endpointFailures.removeValue(forKey: pick.index)
            return .opened(connection)
        } catch {
            endpointFailures[pick.index] = configuration.nowProvider()
            lastError = String(describing: error)
            return .failed
        }
    }

    // Health-aware round-robin: prefer endpoints not in the failure-cooldown
    // window. Falls back to the cursor's primary candidate if every endpoint
    // is currently in cooldown.
    private func nextEndpoint() -> (index: Int, endpoint: ClickHouseEndpoint) {
        let now = configuration.nowProvider()
        let cooldown = configuration.endpointFailureCooldown
        let count = configuration.endpoints.count
        let primaryIndex = endpointCursor % count
        endpointCursor += 1
        if !isInCooldown(index: primaryIndex, now: now, cooldown: cooldown) {
            return (primaryIndex, configuration.endpoints[primaryIndex])
        }
        return firstHealthyOrPrimary(primaryIndex: primaryIndex, count: count, now: now, cooldown: cooldown)
    }

    private func firstHealthyOrPrimary(primaryIndex: Int, count: Int, now: NIODeadline, cooldown: TimeAmount) -> (index: Int, endpoint: ClickHouseEndpoint) {
        for offset in 1..<count {
            let candidateIndex = (primaryIndex + offset) % count
            if !isInCooldown(index: candidateIndex, now: now, cooldown: cooldown) {
                return (candidateIndex, configuration.endpoints[candidateIndex])
            }
        }
        return (primaryIndex, configuration.endpoints[primaryIndex])
    }

    private func isInCooldown(index: Int, now: NIODeadline, cooldown: TimeAmount) -> Bool {
        guard let failedAt = endpointFailures[index] else { return false }
        return now < failedAt + cooldown
    }

}
