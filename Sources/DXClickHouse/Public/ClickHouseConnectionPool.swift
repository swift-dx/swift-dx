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

import Dispatch
import Foundation

// Production-grade pool of AsyncClickHouseConnection instances.
//
// Capability summary:
//
//   * Multi-endpoint round-robin + failover. The pool's configured
//     `endpoints` list is iterated in a round-robin each time a new
//     connection has to be opened; if a given endpoint cannot be
//     reached, the pool transparently tries the next. Only when every
//     endpoint has failed in one rotation does
//     `ClickHouseError.endpointsExhausted` surface to the caller.
//
//   * Acquire timeout. Bounded wait when the pool is saturated.
//
//   * Idle TTL + max lifetime. Connections older than
//     `maxConnectionLifetime`, or that sat unused for longer than
//     `idleConnectionTTL`, are closed and replaced when next looked at.
//     A background eviction task periodically sweeps the idle stack
//     for stale entries so a pool that becomes briefly cold does not
//     keep stale TCP connections forever.
//
//   * Preflight ping. When `preflightPing == true` a recycled idle
//     connection is round-tripped through `Ping → Pong` before being
//     handed back to a caller. If the ping fails (server dropped the
//     socket, broker restart, network partition), the pool discards the
//     stale connection and opens a fresh one for the caller.
//
// Each underlying connection is single-threaded on its own dedicated
// DispatchQueue worker; the pool's only job is to hand out one
// connection per concurrent caller, up to `maxConnections`, and
// serialise the rest behind an FIFO waiter queue.
public actor ClickHouseConnectionPool {

    public struct Configuration: Sendable {

        public let endpoints: [ClickHouseEndpoint]
        public let user: String
        public let password: String
        public let database: String
        public let minConnections: Int
        public let maxConnections: Int
        public let acquireTimeout: Duration
        public let idleConnectionTTL: Duration
        public let maxConnectionLifetime: Duration
        public let preflightPing: Bool
        public let evictionInterval: Duration

        // Multi-endpoint constructor. Pool round-robins across
        // `endpoints` for every new connection it opens. If an
        // endpoint is unreachable, the pool fails over to the next
        // entry; only when every endpoint has been tried does the
        // open fail with `ClickHouseError.endpointsExhausted`.
        public init(
            endpoints: [ClickHouseEndpoint],
            user: String = "default",
            password: String = "",
            database: String = "default",
            minConnections: Int = 1,
            maxConnections: Int = 16,
            acquireTimeout: Duration = .seconds(30),
            idleConnectionTTL: Duration = .seconds(300),
            maxConnectionLifetime: Duration = .seconds(3600),
            preflightPing: Bool = false,
            evictionInterval: Duration = .seconds(30)
        ) {
            self.endpoints = endpoints
            self.user = user
            self.password = password
            self.database = database
            self.minConnections = minConnections
            self.maxConnections = maxConnections
            self.acquireTimeout = acquireTimeout
            self.idleConnectionTTL = idleConnectionTTL
            self.maxConnectionLifetime = maxConnectionLifetime
            self.preflightPing = preflightPing
            self.evictionInterval = evictionInterval
        }

        // Single-endpoint convenience constructor. Wraps `host`/`port`
        // into a one-element `endpoints` list and forwards.
        public init(
            host: String,
            port: Int,
            user: String = "default",
            password: String = "",
            database: String = "default",
            minConnections: Int = 1,
            maxConnections: Int = 16,
            acquireTimeout: Duration = .seconds(30),
            idleConnectionTTL: Duration = .seconds(300),
            maxConnectionLifetime: Duration = .seconds(3600),
            preflightPing: Bool = false,
            evictionInterval: Duration = .seconds(30)
        ) {
            self.init(
                endpoints: [ClickHouseEndpoint(host: host, port: port)],
                user: user,
                password: password,
                database: database,
                minConnections: minConnections,
                maxConnections: maxConnections,
                acquireTimeout: acquireTimeout,
                idleConnectionTTL: idleConnectionTTL,
                maxConnectionLifetime: maxConnectionLifetime,
                preflightPing: preflightPing,
                evictionInterval: evictionInterval
            )
        }
    }

    public struct Stats: Sendable, Equatable {

        public let idleConnections: Int
        public let inUseConnections: Int
        public let waiters: Int
        public let openedTotal: Int
        public let closedTotal: Int
        public let leasesGranted: Int
        public let leasesReleased: Int
        public let acquireTimeouts: Int
        public let maxConnections: Int
        public let evictedByIdleTTL: Int
        public let evictedByLifetime: Int
        public let evictedByPreflight: Int
        public let endpointFailovers: Int
    }

    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case poolClosed
        case acquireTimedOut(after: Duration)
        case openFailed(reason: String)
        case allEndpointsFailed(failures: [ClickHouseEndpointFailure])
        case invalidConfiguration(reason: String)

        public var description: String {
            switch self {
            case .poolClosed: "pool is closed"
            case .acquireTimedOut(let after): "acquire timed out after \(after)"
            case .openFailed(let reason): "failed to open underlying connection: \(reason)"
            case .allEndpointsFailed(let failures):
                "every endpoint failed: \(failures.map { $0.description }.joined(separator: "; "))"
            case .invalidConfiguration(let reason): "invalid pool configuration: \(reason)"
            }
        }
    }

    private enum WaiterState {
        case pending(CheckedContinuation<PooledConnection, Error>)
        case completed
    }

    private final class Waiter: @unchecked Sendable {
        var state: WaiterState
        let token: Int
        init(token: Int, continuation: CheckedContinuation<PooledConnection, Error>) {
            self.token = token
            self.state = .pending(continuation)
        }
        func resume(returning entry: PooledConnection) {
            guard case .pending(let continuation) = state else { return }
            state = .completed
            continuation.resume(returning: entry)
        }
        func resume(throwing error: Error) {
            guard case .pending(let continuation) = state else { return }
            state = .completed
            continuation.resume(throwing: error)
        }
    }

    private enum EvictionTaskState: Sendable {
        case idle
        case running(Task<Void, Never>)
    }

    // Pool bookkeeping per connection: the connection itself plus the
    // wall-clock timestamps used by idle-TTL and max-lifetime eviction.
    private struct PooledConnection {
        let connection: AsyncClickHouseConnection
        let openedAt: Date
        var lastUsedAt: Date
    }

    private let configuration: Configuration
    private var idle: [PooledConnection] = []
    private var inUseCount = 0
    private var waiters: [Waiter] = []
    private var nextWaiterToken = 0
    private var isShutdown = false
    private var nextEndpointIndex = 0

    private var openedTotal = 0
    private var closedTotal = 0
    private var leasesGranted = 0
    private var leasesReleased = 0
    private var acquireTimeouts = 0
    private var evictedByIdleTTL = 0
    private var evictedByLifetime = 0
    private var evictedByPreflight = 0
    private var endpointFailovers = 0

    private var evictionTaskState: EvictionTaskState = .idle

    // Single-endpoint, no-TTL-tuning legacy constructor preserved for
    // backwards compatibility with the original pool surface that
    // shipped during the layer-back campaign. Always returns a pool
    // with default idle TTL, max lifetime, and eviction interval.
    public init(
        host: String,
        port: Int,
        user: String = "default",
        password: String = "",
        database: String = "default",
        minConnections: Int = 1,
        maxConnections: Int = 16,
        acquireTimeout: Duration = .seconds(30)
    ) async throws(Failure) {
        let configuration = Configuration(
            host: host,
            port: port,
            user: user,
            password: password,
            database: database,
            minConnections: minConnections,
            maxConnections: maxConnections,
            acquireTimeout: acquireTimeout
        )
        try await self.init(configuration: configuration)
    }

    public init(configuration: Configuration) async throws(Failure) {
        try Self.validate(configuration)
        self.configuration = configuration
        let seedTarget = min(configuration.minConnections, configuration.maxConnections)
        idle.reserveCapacity(configuration.maxConnections)
        let prewarm = try await Self.prewarmConnections(
            configuration: configuration,
            seedTarget: seedTarget,
            startingIndex: 0
        )
        self.nextEndpointIndex = prewarm.endingIndex
        self.idle.append(contentsOf: prewarm.entries)
        self.openedTotal = prewarm.entries.count
        self.endpointFailovers = prewarm.failovers
        self.startEvictionTask()
    }

    // Reject a structurally-invalid pool configuration with a typed
    // error at construction instead of trapping the process. A server
    // aiming for high availability must not crash because a max-pool-size
    // was computed to zero or a min/max pair was inverted; the caller
    // gets `Failure.invalidConfiguration` and decides how to recover.
    private static func validate(_ configuration: Configuration) throws(Failure) {
        let checks: [(passes: Bool, reason: String)] = [
            (configuration.maxConnections >= 1, "maxConnections must be >= 1, got \(configuration.maxConnections)"),
            (configuration.minConnections >= 0, "minConnections must be >= 0, got \(configuration.minConnections)"),
            (configuration.minConnections <= configuration.maxConnections, "minConnections (\(configuration.minConnections)) must be <= maxConnections (\(configuration.maxConnections))"),
            (!configuration.endpoints.isEmpty, "at least one endpoint must be supplied"),
        ]
        for check in checks where !check.passes {
            throw Failure.invalidConfiguration(reason: check.reason)
        }
    }

    private struct PrewarmResult {
        let entries: [PooledConnection]
        let failovers: Int
        let endingIndex: Int
    }

    private static func prewarmConnections(
        configuration: Configuration,
        seedTarget: Int,
        startingIndex: Int
    ) async throws(Failure) -> PrewarmResult {
        var prewarmed: [PooledConnection] = []
        var prewarmFailovers = 0
        var cursor = startingIndex
        prewarmed.reserveCapacity(seedTarget)
        for _ in 0..<seedTarget {
            let outcome = try await openOrCleanup(
                configuration: configuration,
                cursor: cursor,
                prewarmed: prewarmed
            )
            cursor = (cursor + 1) % configuration.endpoints.count
            prewarmed.append(outcome.entry)
            prewarmFailovers += outcome.failoverCount
        }
        return PrewarmResult(entries: prewarmed, failovers: prewarmFailovers, endingIndex: cursor)
    }

    private static func openOrCleanup(
        configuration: Configuration,
        cursor: Int,
        prewarmed: [PooledConnection]
    ) async throws(Failure) -> FailoverOutcome {
        do {
            return try await Self.openWithFailover(
                configuration: configuration,
                startingIndex: cursor
            )
        } catch let failure as Failure {
            await closeAll(prewarmed)
            throw failure
        } catch {
            await closeAll(prewarmed)
            throw Failure.openFailed(reason: String(describing: error))
        }
    }

    private static func closeAll(_ entries: [PooledConnection]) async {
        for opened in entries {
            await opened.connection.close()
        }
    }

    // Hot path. Single acquire actor-hop on the pool, then the body
    // calls methods on the AsyncClickHouseConnection actor directly.
    // The body cannot take the connection as an `isolated` parameter
    // under Swift 6 sending checks because the connection value crosses
    // the pool-actor → caller-task isolation boundary here. The
    // connection methods are already actor-isolated, so the body still
    // has serialised access to a single connection during its lifetime.
    @discardableResult
    public func withConnection<Value: Sendable>(
        _ body: sending (AsyncClickHouseConnection) async throws -> Value
    ) async throws -> Value {
        let entry = try await acquire()
        do {
            let value = try await body(entry.connection)
            release(entry)
            return value
        } catch {
            await discardIfBroken(entry, after: error)
            throw error
        }
    }

    // A lease that ends in failure must not blindly recycle the connection.
    // If the failure left the socket broken or the protocol stream desynced,
    // returning it to the idle stack — or handing it straight to a waiting
    // caller — would pass the damage to the next lease. Only a clean
    // server-side query rejection leaves the connection reusable.
    private func discardIfBroken(_ entry: PooledConnection, after error: any Error) async {
        if connectionSurvives(error) {
            release(entry)
        } else {
            await discardBrokenConnection(entry)
        }
    }

    private func connectionSurvives(_ error: any Error) -> Bool {
        guard let typed = error as? ClickHouseError else { return true }
        return Self.connectionIsCleanAfter(typed)
    }

    private static func connectionIsCleanAfter(_ error: ClickHouseError) -> Bool {
        switch error {
        case .queryFailed:
            return true
        case .connectionFailed, .socketIOFailed, .unexpectedEOF, .protocolError,
             .reconnectExhausted, .endpointsExhausted, .queryTimeout:
            return false
        }
    }

    private func discardBrokenConnection(_ entry: PooledConnection) async {
        inUseCount -= 1
        leasesReleased += 1
        await entry.connection.close()
        closedTotal += 1
        if isShutdown { return }
        await serveWaiterWithFreshConnection()
    }

    // Discarding a broken connection frees a capacity slot but, unlike
    // release(), wakes no parked waiter. Open a replacement for the next
    // waiter so it is not left blocked until its acquire timeout.
    private func serveWaiterWithFreshConnection() async {
        guard canServeNewWaiter else { return }
        let waiter = waiters.removeFirst()
        await openAndHand(to: waiter)
    }

    private var canServeNewWaiter: Bool {
        !waiters.isEmpty && (inUseCount + idle.count) < configuration.maxConnections
    }

    private func openAndHand(to waiter: Waiter) async {
        inUseCount += 1
        do {
            let entry = try await openWithFailover()
            openedTotal += 1
            waiter.resume(returning: entry)
        } catch {
            inUseCount -= 1
            waiter.resume(throwing: error)
        }
    }

    public func close() async {
        guard !isShutdown else { return }
        isShutdown = true
        cancelEvictionTask()
        failPendingWaiters()
        await closeIdleConnections()
    }

    private func cancelEvictionTask() {
        if case .running(let task) = evictionTaskState {
            task.cancel()
        }
        evictionTaskState = .idle
    }

    private func failPendingWaiters() {
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume(throwing: Failure.poolClosed)
        }
    }

    private func closeIdleConnections() async {
        let toClose = idle
        idle.removeAll(keepingCapacity: false)
        for entry in toClose {
            await entry.connection.close()
            closedTotal += 1
        }
    }

    public func stats() -> Stats {
        Stats(
            idleConnections: idle.count,
            inUseConnections: inUseCount,
            waiters: waiters.count,
            openedTotal: openedTotal,
            closedTotal: closedTotal,
            leasesGranted: leasesGranted,
            leasesReleased: leasesReleased,
            acquireTimeouts: acquireTimeouts,
            maxConnections: configuration.maxConnections,
            evictedByIdleTTL: evictedByIdleTTL,
            evictedByLifetime: evictedByLifetime,
            evictedByPreflight: evictedByPreflight,
            endpointFailovers: endpointFailovers
        )
    }

    private func acquire() async throws -> PooledConnection {
        if isShutdown { throw Failure.poolClosed }
        switch await reuseHealthyIdleEntry() {
        case .recycled(let entry):
            return entry
        case .idleExhausted:
            break
        }
        if (inUseCount + idle.count) < configuration.maxConnections {
            return try await openFreshConnection()
        }
        return try await suspendForLease()
    }

    private enum IdleEntryDecision {
        case useFreshened(PooledConnection)
        case evict(PooledConnection, CounterKey)
    }

    private enum RecycleOutcome {
        case recycled(PooledConnection)
        case idleExhausted
    }

    private enum StalenessCheck {
        case stale(CounterKey)
        case fresh
    }

    private func classifyIdleEntry(_ entry: PooledConnection) async -> IdleEntryDecision {
        if case .stale(let counter) = synchronousStaleness(of: entry) {
            return .evict(entry, counter)
        }
        if configuration.preflightPing, await !preflight(connection: entry.connection) {
            return .evict(entry, .evictedByPreflightKey)
        }
        var freshened = entry
        freshened.lastUsedAt = Date()
        return .useFreshened(freshened)
    }

    private func synchronousStaleness(of entry: PooledConnection) -> StalenessCheck {
        if entryIsExpired(entry) { return .stale(.evictedByIdleTTLKey) }
        if entryExceedsLifetime(entry) { return .stale(.evictedByLifetimeKey) }
        return .fresh
    }

    private func reuseHealthyIdleEntry() async -> RecycleOutcome {
        while let entry = idle.popLast() {
            switch await classifyIdleEntry(entry) {
            case .evict(let stale, let counter):
                await closeAndCount(stale, by: counter)
            case .useFreshened(let freshened):
                inUseCount += 1
                leasesGranted += 1
                return .recycled(freshened)
            }
        }
        return .idleExhausted
    }

    private func openFreshConnection() async throws -> PooledConnection {
        inUseCount += 1
        do {
            let entry = try await openWithFailover()
            openedTotal += 1
            leasesGranted += 1
            return entry
        } catch {
            inUseCount -= 1
            throw error
        }
    }

    private func entryIsExpired(_ entry: PooledConnection) -> Bool {
        guard configuration.idleConnectionTTL > .zero else { return false }
        let elapsed = Date().timeIntervalSince(entry.lastUsedAt)
        return elapsed >= durationToSeconds(configuration.idleConnectionTTL)
    }

    private func entryExceedsLifetime(_ entry: PooledConnection) -> Bool {
        guard configuration.maxConnectionLifetime > .zero else { return false }
        let elapsed = Date().timeIntervalSince(entry.openedAt)
        return elapsed >= durationToSeconds(configuration.maxConnectionLifetime)
    }

    private func preflight(connection: AsyncClickHouseConnection) async -> Bool {
        do {
            try await connection.pingOnce()
            return true
        } catch {
            return false
        }
    }

    // Counter accessors used by `closeAndCount`. Swift 6 actors do not
    // allow `KeyPath<Self, Int>` to write through, so we expose tiny
    // mutating helpers indexed by a `CounterKey` enum.
    private enum CounterKey {
        case evictedByIdleTTLKey
        case evictedByLifetimeKey
        case evictedByPreflightKey
    }

    private func closeAndCount(_ entry: PooledConnection, by counter: CounterKey) async {
        await entry.connection.close()
        closedTotal += 1
        incrementCounter(counter)
    }

    private func incrementCounter(_ counter: CounterKey) {
        switch counter {
        case .evictedByIdleTTLKey: evictedByIdleTTL += 1
        case .evictedByLifetimeKey: evictedByLifetime += 1
        case .evictedByPreflightKey: evictedByPreflight += 1
        }
    }

    private func suspendForLease() async throws -> PooledConnection {
        let token = nextWaiterToken
        nextWaiterToken += 1
        let timeoutDuration = configuration.acquireTimeout
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeoutDuration)
            await self?.timeoutWaiter(token: token)
        }
        do {
            let entry = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PooledConnection, Error>) in
                    let waiter = Waiter(token: token, continuation: continuation)
                    waiters.append(waiter)
                }
            } onCancel: {
                Task { [weak self] in await self?.cancelWaiter(token: token) }
            }
            timeoutTask.cancel()
            leasesGranted += 1
            return entry
        } catch {
            timeoutTask.cancel()
            throw error
        }
    }

    private func timeoutWaiter(token: Int) {
        guard let waiterIndex = waiters.firstIndex(where: { $0.token == token }) else { return }
        let waiter = waiters.remove(at: waiterIndex)
        acquireTimeouts += 1
        waiter.resume(throwing: Failure.acquireTimedOut(after: configuration.acquireTimeout))
    }

    // Resumes a parked waiter with CancellationError when the acquiring
    // task is cancelled, so a request that gives up no longer blocks until
    // the acquire timeout fires. The Waiter's resume guard makes this safe
    // against a concurrent release() or timeout that already resumed it;
    // if so, the waiter is gone from the queue and this is a no-op.
    private func cancelWaiter(token: Int) {
        guard let waiterIndex = waiters.firstIndex(where: { $0.token == token }) else { return }
        let waiter = waiters.remove(at: waiterIndex)
        waiter.resume(throwing: CancellationError())
    }

    private func release(_ entry: PooledConnection) {
        inUseCount -= 1
        leasesReleased += 1
        if isShutdown {
            Task { await entry.connection.close() }
            return
        }
        var refreshed = entry
        refreshed.lastUsedAt = Date()
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            inUseCount += 1
            waiter.resume(returning: refreshed)
            return
        }
        idle.append(refreshed)
    }

    // Open one connection, walking the configured `endpoints` list in
    // round-robin until one succeeds. Increments `endpointFailovers`
    // each time an open is rejected. Throws
    // `Failure.allEndpointsFailed` when every endpoint refuses.
    private func openWithFailover() async throws -> PooledConnection {
        var failures: [ClickHouseEndpointFailure] = []
        for _ in 0..<configuration.endpoints.count {
            let index = nextEndpointIndex
            nextEndpointIndex = (nextEndpointIndex + 1) % configuration.endpoints.count
            switch await Self.tryOpenEndpoint(configuration: configuration, endpointIndex: index) {
            case .success(let entry):
                return entry
            case .softFailed(let endpointFailure):
                failures.append(endpointFailure)
                endpointFailovers += 1
            case .hardFailed(let failure):
                throw failure
            }
        }
        throw Failure.allEndpointsFailed(failures: failures)
    }

    private enum EndpointOpenAttempt {
        case success(PooledConnection)
        case softFailed(ClickHouseEndpointFailure)
        case hardFailed(Failure)
    }

    private static func tryOpenEndpoint(
        configuration: Configuration,
        endpointIndex: Int
    ) async -> EndpointOpenAttempt {
        do {
            let entry = try await openConnection(configuration: configuration, endpointIndex: endpointIndex)
            return .success(entry)
        } catch let failure as Failure {
            return classifyOpenFailure(failure, endpoint: configuration.endpoints[endpointIndex])
        } catch {
            let endpoint = configuration.endpoints[endpointIndex]
            return .softFailed(ClickHouseEndpointFailure(host: endpoint.host, port: endpoint.port, reason: String(describing: error)))
        }
    }

    private static func classifyOpenFailure(
        _ failure: Failure,
        endpoint: ClickHouseEndpoint
    ) -> EndpointOpenAttempt {
        if case .openFailed(let reason) = failure {
            return .softFailed(ClickHouseEndpointFailure(host: endpoint.host, port: endpoint.port, reason: reason))
        }
        return .hardFailed(failure)
    }

    // Result of a static failover walk: the connection plus the number
    // of endpoints that were skipped before the open succeeded. The
    // skipped count rolls up into the actor's `endpointFailovers`
    // counter once `init` returns.
    private struct FailoverOutcome {
        let entry: PooledConnection
        let failoverCount: Int
    }

    // Static variant of `openWithFailover` usable during `init` before
    // `self` is fully isolated. Walks the endpoint list starting at
    // `startingIndex` and returns the first one that opens.
    private static func openWithFailover(
        configuration: Configuration,
        startingIndex: Int
    ) async throws -> FailoverOutcome {
        var failures: [ClickHouseEndpointFailure] = []
        let count = configuration.endpoints.count
        for offset in 0..<count {
            let index = (startingIndex + offset) % count
            switch await tryOpenEndpoint(configuration: configuration, endpointIndex: index) {
            case .success(let entry):
                return FailoverOutcome(entry: entry, failoverCount: failures.count)
            case .softFailed(let endpointFailure):
                failures.append(endpointFailure)
            case .hardFailed(let failure):
                throw failure
            }
        }
        throw Failure.allEndpointsFailed(failures: failures)
    }

    private static func openConnection(configuration: Configuration, endpointIndex: Int) async throws -> PooledConnection {
        let endpoint = configuration.endpoints[endpointIndex]
        do {
            let now = Date()
            let connection = try await AsyncClickHouseConnection(
                host: endpoint.host,
                port: endpoint.port,
                user: configuration.user,
                password: configuration.password,
                database: configuration.database
            )
            return PooledConnection(connection: connection, openedAt: now, lastUsedAt: now)
        } catch {
            throw Failure.openFailed(reason: String(describing: error))
        }
    }

    private func startEvictionTask() {
        guard configuration.evictionInterval > .zero else { return }
        let interval = configuration.evictionInterval
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                await self?.sweepIdleConnections()
            }
        }
        evictionTaskState = .running(task)
    }

    private func sweepIdleConnections() async {
        guard !isShutdown else { return }
        var survivors: [PooledConnection] = []
        survivors.reserveCapacity(idle.count)
        let snapshot = idle
        idle.removeAll(keepingCapacity: true)
        for entry in snapshot {
            await sweepOne(entry, into: &survivors)
        }
        idle = survivors
    }

    private func sweepOne(_ entry: PooledConnection, into survivors: inout [PooledConnection]) async {
        if entryIsExpired(entry) {
            await closeAndCount(entry, by: .evictedByIdleTTLKey)
        } else if entryExceedsLifetime(entry) {
            await closeAndCount(entry, by: .evictedByLifetimeKey)
        } else {
            survivors.append(entry)
        }
    }

    private func durationToSeconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
