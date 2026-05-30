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

        public var description: String {
            switch self {
            case .poolClosed: "pool is closed"
            case .acquireTimedOut(let after): "acquire timed out after \(after)"
            case .openFailed(let reason): "failed to open underlying connection: \(reason)"
            case .allEndpointsFailed(let failures):
                "every endpoint failed: \(failures.map { $0.description }.joined(separator: "; "))"
            }
        }
    }

    private final class Waiter: @unchecked Sendable {
        var continuation: CheckedContinuation<PooledConnection, Error>?
        let token: Int
        init(token: Int, continuation: CheckedContinuation<PooledConnection, Error>) {
            self.token = token
            self.continuation = continuation
        }
        func resume(returning entry: PooledConnection) {
            guard let pending = continuation else { return }
            continuation = nil
            pending.resume(returning: entry)
        }
        func resume(throwing error: Error) {
            guard let pending = continuation else { return }
            continuation = nil
            pending.resume(throwing: error)
        }
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

    private var evictionTask: Task<Void, Never>?

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
    ) async throws {
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

    public init(configuration: Configuration) async throws {
        precondition(configuration.minConnections >= 0, "minConnections must be >= 0")
        precondition(configuration.maxConnections >= 1, "maxConnections must be >= 1")
        precondition(configuration.minConnections <= configuration.maxConnections, "minConnections must be <= maxConnections")
        precondition(!configuration.endpoints.isEmpty, "at least one endpoint must be supplied")
        self.configuration = configuration
        let seedTarget = min(configuration.minConnections, configuration.maxConnections)
        idle.reserveCapacity(configuration.maxConnections)
        var prewarmed: [PooledConnection] = []
        var prewarmFailovers = 0
        prewarmed.reserveCapacity(seedTarget)
        for _ in 0..<seedTarget {
            do {
                let outcome = try await Self.openWithFailover(
                    configuration: configuration,
                    startingIndex: nextEndpointIndex
                )
                nextEndpointIndex = (nextEndpointIndex + 1) % configuration.endpoints.count
                prewarmed.append(outcome.entry)
                prewarmFailovers += outcome.failoverCount
            } catch {
                for opened in prewarmed {
                    await opened.connection.close()
                }
                if let failure = error as? Failure {
                    throw failure
                }
                throw Failure.openFailed(reason: String(describing: error))
            }
        }
        self.idle.append(contentsOf: prewarmed)
        self.openedTotal = prewarmed.count
        self.endpointFailovers = prewarmFailovers
        self.startEvictionTask()
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
            release(entry)
            throw error
        }
    }

    public func close() async {
        guard !isShutdown else { return }
        isShutdown = true
        evictionTask?.cancel()
        evictionTask = nil
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume(throwing: Failure.poolClosed)
        }
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
        while var entry = idle.popLast() {
            if entryIsExpired(entry) {
                await closeAndCount(entry, by: .evictedByIdleTTLKey)
                continue
            }
            if entryExceedsLifetime(entry) {
                await closeAndCount(entry, by: .evictedByLifetimeKey)
                continue
            }
            if configuration.preflightPing {
                let healthy = await preflight(connection: entry.connection)
                if !healthy {
                    await closeAndCount(entry, by: .evictedByPreflightKey)
                    continue
                }
            }
            entry.lastUsedAt = Date()
            inUseCount += 1
            leasesGranted += 1
            return entry
        }
        if (inUseCount + idle.count) < configuration.maxConnections {
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
        return try await suspendForLease()
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
            try await connection.ping()
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
            let entry = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PooledConnection, Error>) in
                let waiter = Waiter(token: token, continuation: continuation)
                waiters.append(waiter)
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
            do {
                return try await Self.openConnection(configuration: configuration, endpointIndex: index)
            } catch let failure as Failure {
                if case .openFailed(let reason) = failure {
                    let endpoint = configuration.endpoints[index]
                    failures.append(ClickHouseEndpointFailure(host: endpoint.host, port: endpoint.port, reason: reason))
                    endpointFailovers += 1
                    continue
                }
                throw failure
            } catch {
                let endpoint = configuration.endpoints[index]
                failures.append(ClickHouseEndpointFailure(host: endpoint.host, port: endpoint.port, reason: String(describing: error)))
                endpointFailovers += 1
                continue
            }
        }
        throw Failure.allEndpointsFailed(failures: failures)
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
            do {
                let entry = try await openConnection(configuration: configuration, endpointIndex: index)
                return FailoverOutcome(entry: entry, failoverCount: failures.count)
            } catch let failure as Failure {
                if case .openFailed(let reason) = failure {
                    let endpoint = configuration.endpoints[index]
                    failures.append(ClickHouseEndpointFailure(host: endpoint.host, port: endpoint.port, reason: reason))
                    continue
                }
                throw failure
            } catch {
                let endpoint = configuration.endpoints[index]
                failures.append(ClickHouseEndpointFailure(host: endpoint.host, port: endpoint.port, reason: String(describing: error)))
                continue
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
        evictionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                await self?.sweepIdleConnections()
            }
        }
    }

    private func sweepIdleConnections() async {
        guard !isShutdown else { return }
        var survivors: [PooledConnection] = []
        survivors.reserveCapacity(idle.count)
        let snapshot = idle
        idle.removeAll(keepingCapacity: true)
        for entry in snapshot {
            if entryIsExpired(entry) {
                await closeAndCount(entry, by: .evictedByIdleTTLKey)
                continue
            }
            if entryExceedsLifetime(entry) {
                await closeAndCount(entry, by: .evictedByLifetimeKey)
                continue
            }
            survivors.append(entry)
        }
        idle = survivors
    }

    private func durationToSeconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
