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

// Semaphore-bounded pool of AsyncRawClickHouseConnection instances.
//
// Each underlying connection is single-threaded on its own dedicated
// DispatchQueue worker (see AsyncRawClickHouseConnection); the pool's
// only job is to hand out one connection per concurrent caller, up
// to maxConnections, and serialise the rest behind an FIFO waiter
// queue. There is no per-call locking on the hot path: once a
// connection is acquired, the caller drives it directly via the
// actor's isolated methods. The pool is touched only on acquire and
// release.
//
// The pool itself is implemented as an actor for waiter-queue and
// idle-stack invariants. acquire() / release() each cost one actor
// hop. The hot path (sendQuery + drainBlocks etc.) goes straight to
// the AsyncRawClickHouseConnection actor — the pool is NOT in the
// hot path of any query.
//
// Acquire semantics:
//
//   * If there is an idle connection in the stack, pop and return it.
//   * Else if we have room under maxConnections, open a new one.
//   * Else suspend the caller on a FIFO waiter queue with a
//     deadline of acquireTimeout. Resumption happens from release()
//     or from a timeout task.
//
// Release semantics:
//
//   * If there is a waiter, hand the connection directly to the
//     head-of-queue waiter. No idle-stack hop.
//   * Else push onto the idle stack.
//
// On close(), every idle connection is closed and any in-flight
// waiter is failed with poolClosed. The actor sets isShutdown so
// subsequent acquires fail fast.
public actor RawClickHouseConnectionPool {

    public struct Configuration: Sendable {

        public let host: String
        public let port: Int
        public let user: String
        public let password: String
        public let database: String
        public let minConnections: Int
        public let maxConnections: Int
        public let acquireTimeout: Duration

        public init(
            host: String,
            port: Int,
            user: String = "default",
            password: String = "",
            database: String = "default",
            minConnections: Int = 1,
            maxConnections: Int = 16,
            acquireTimeout: Duration = .seconds(30)
        ) {
            self.host = host
            self.port = port
            self.user = user
            self.password = password
            self.database = database
            self.minConnections = minConnections
            self.maxConnections = maxConnections
            self.acquireTimeout = acquireTimeout
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
    }

    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case poolClosed
        case acquireTimedOut(after: Duration)
        case openFailed(reason: String)

        public var description: String {
            switch self {
            case .poolClosed: "pool is closed"
            case .acquireTimedOut(let after): "acquire timed out after \(after)"
            case .openFailed(let reason): "failed to open underlying connection: \(reason)"
            }
        }
    }

    private final class Waiter: @unchecked Sendable {
        var continuation: CheckedContinuation<AsyncRawClickHouseConnection, Error>?
        let token: Int
        init(token: Int, continuation: CheckedContinuation<AsyncRawClickHouseConnection, Error>) {
            self.token = token
            self.continuation = continuation
        }
        func resume(returning connection: AsyncRawClickHouseConnection) {
            guard let pending = continuation else { return }
            continuation = nil
            pending.resume(returning: connection)
        }
        func resume(throwing error: Error) {
            guard let pending = continuation else { return }
            continuation = nil
            pending.resume(throwing: error)
        }
    }

    private let configuration: Configuration
    private var idle: [AsyncRawClickHouseConnection] = []
    private var inUseCount = 0
    private var waiters: [Waiter] = []
    private var nextWaiterToken = 0
    private var isShutdown = false

    private var openedTotal = 0
    private var closedTotal = 0
    private var leasesGranted = 0
    private var leasesReleased = 0
    private var acquireTimeouts = 0

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
        self.configuration = configuration
        let seedTarget = min(configuration.minConnections, configuration.maxConnections)
        idle.reserveCapacity(configuration.maxConnections)
        var prewarmed: [AsyncRawClickHouseConnection] = []
        prewarmed.reserveCapacity(seedTarget)
        for _ in 0..<seedTarget {
            do {
                let connection = try await Self.openConnection(configuration: configuration)
                prewarmed.append(connection)
            } catch {
                for opened in prewarmed {
                    await opened.close()
                }
                throw Failure.openFailed(reason: String(describing: error))
            }
        }
        self.idle.append(contentsOf: prewarmed)
        self.openedTotal = prewarmed.count
    }

    // Hot path. Single acquire actor-hop on the pool, then the body
    // calls methods on the AsyncRawClickHouseConnection actor directly
    // (paying one actor-hop per call inside the body, which is the
    // same isolation cost as not using the pool at all). Single release
    // actor-hop at the end. The pool itself is never in the data path
    // of any wire operation.
    //
    // Note: the body cannot take the connection as an `isolated`
    // parameter under Swift 6 sending checks because the connection
    // value crosses the pool-actor → caller-task isolation boundary
    // here. The connection methods are already actor-isolated, so the
    // body still has serialised access to a single connection during
    // its lifetime.
    @discardableResult
    public func withConnection<Value: Sendable>(
        _ body: sending (AsyncRawClickHouseConnection) async throws -> Value
    ) async throws -> Value {
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

    public func close() async {
        guard !isShutdown else { return }
        isShutdown = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume(throwing: Failure.poolClosed)
        }
        let toClose = idle
        idle.removeAll(keepingCapacity: false)
        for connection in toClose {
            await connection.close()
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
            maxConnections: configuration.maxConnections
        )
    }

    private func acquire() async throws -> AsyncRawClickHouseConnection {
        if isShutdown {
            throw Failure.poolClosed
        }
        if let connection = idle.popLast() {
            inUseCount += 1
            leasesGranted += 1
            return connection
        }
        if (inUseCount + idle.count) < configuration.maxConnections {
            inUseCount += 1
            do {
                let connection = try await Self.openConnection(configuration: configuration)
                openedTotal += 1
                leasesGranted += 1
                return connection
            } catch {
                inUseCount -= 1
                throw Failure.openFailed(reason: String(describing: error))
            }
        }
        return try await suspendForLease()
    }

    private func suspendForLease() async throws -> AsyncRawClickHouseConnection {
        let token = nextWaiterToken
        nextWaiterToken += 1
        let timeoutDuration = configuration.acquireTimeout
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeoutDuration)
            await self?.timeoutWaiter(token: token)
        }
        do {
            let connection = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AsyncRawClickHouseConnection, Error>) in
                let waiter = Waiter(token: token, continuation: continuation)
                waiters.append(waiter)
            }
            timeoutTask.cancel()
            leasesGranted += 1
            return connection
        } catch {
            timeoutTask.cancel()
            throw error
        }
    }

    private func timeoutWaiter(token: Int) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        let waiter = waiters.remove(at: index)
        acquireTimeouts += 1
        waiter.resume(throwing: Failure.acquireTimedOut(after: configuration.acquireTimeout))
    }

    private func release(_ connection: AsyncRawClickHouseConnection) {
        inUseCount -= 1
        leasesReleased += 1
        if isShutdown {
            Task { await connection.close() }
            return
        }
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            inUseCount += 1
            waiter.resume(returning: connection)
            return
        }
        idle.append(connection)
    }

    private static func openConnection(configuration: Configuration) async throws -> AsyncRawClickHouseConnection {
        try await AsyncRawClickHouseConnection(
            host: configuration.host,
            port: configuration.port,
            user: configuration.user,
            password: configuration.password,
            database: configuration.database
        )
    }
}
