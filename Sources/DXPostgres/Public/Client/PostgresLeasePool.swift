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
import Logging
import Synchronization

/// A connection pool whose callers run synchronously in their own lane. A caller
/// leases a connection for the duration of a `withConnection` closure; the closure
/// runs on that connection's dedicated thread, where every query inside it executes
/// back-to-back with no per-query async hand-off, reaching the throughput of the
/// direct synchronous path. Only the lease itself is asynchronous: when every
/// connection is busy the caller suspends until one frees, so the async machinery
/// is paid exactly when callers outnumber connections and never per query.
///
/// The pool heals itself. When a leased query fails because its connection broke,
/// the worker is marked down and a background thread reconnects it forever with
/// capped backoff, returning it to service the moment the server is reachable
/// again. While a connection is down it is simply not leased; a caller that finds
/// every connection down fails fast with ``PostgresError/allConnectionsDown`` rather
/// than blocking, so a server outage surfaces as a prompt error, not a hang, while
/// the pool keeps trying to recover behind it.
///
/// `@unchecked Sendable` is sound because the free list, waiter queue, and health
/// counts are guarded by the lock-held state and each connection is only ever
/// touched on its own thread.
public final class PostgresLeasePool: @unchecked Sendable {

    private static let initialBackoffSeconds = 0.05
    private static let maxBackoffSeconds = 30.0

    private struct PoolState {

        var free: [Int]
        var waiters: [UnsafeContinuation<Int, Error>]
        var healthyCount: Int
        var shuttingDown: Bool
    }

    private enum ConnectionSource: Sendable {

        case reconnectable(PostgresConnectionTarget)
        case fixed
    }

    private let workers: [LeaseWorker]
    private let source: ConnectionSource
    private let logger: Logger
    private let state: Mutex<PoolState>

    public convenience init(host: String, port: Int, username: String, password: String, database: String, applicationName: String, size: Int) throws(PostgresError) {
        let target = PostgresConnectionTarget(host: host, port: port, username: username, password: password, database: database, applicationName: applicationName)
        let count = max(1, size)
        var connections: [BlockingPostgresConnection] = []
        connections.reserveCapacity(count)
        for _ in 0..<count {
            connections.append(try target.connect())
        }
        self.init(connections: connections, source: .reconnectable(target))
    }

    convenience init(connections: [BlockingPostgresConnection]) {
        self.init(connections: connections, source: .fixed)
    }

    private init(connections: [BlockingPostgresConnection], source: ConnectionSource) {
        var workers: [LeaseWorker] = []
        workers.reserveCapacity(connections.count)
        for connection in connections {
            let worker = LeaseWorker(connection: connection)
            worker.start()
            workers.append(worker)
        }
        self.workers = workers
        self.source = source
        self.logger = Logger(label: "dx.postgres.pool")
        self.state = Mutex(PoolState(free: Array(0..<workers.count), waiters: [], healthyCount: workers.count, shuttingDown: false))
    }

    var waiterCount: Int {
        state.withLock { $0.waiters.count }
    }

    var healthyConnectionCount: Int {
        state.withLock { $0.healthyCount }
    }

    public func transaction<Result: Sendable>(_ body: @escaping @Sendable (PostgresTransaction) throws -> Result) async throws -> Result {
        try await withConnection { lease in
            try Self.runTransaction(on: lease, body)
        }
    }

    private static func runTransaction<Result>(on lease: PostgresLeasedConnection, _ body: (PostgresTransaction) throws -> Result) throws -> Result {
        _ = try lease.execute("BEGIN")
        do {
            let result = try body(PostgresTransaction(lease: lease))
            _ = try lease.execute("COMMIT")
            return result
        } catch {
            try rollback(lease, rethrowing: error)
        }
    }

    private static func rollback(_ lease: PostgresLeasedConnection, rethrowing original: Error) throws -> Never {
        do {
            _ = try lease.execute("ROLLBACK")
        } catch {
            throw PostgresError.transportError(reason: "transaction rollback failed: \(error)")
        }
        throw original
    }

    func withConnection<Result: Sendable>(_ body: @escaping @Sendable (PostgresLeasedConnection) throws -> Result) async throws -> Result {
        let index = try await acquire()
        do {
            let result = try await runLeased(index, body)
            release(index)
            return result
        } catch {
            finishLease(index, error)
            throw error
        }
    }

    public func execute(_ sql: String) async throws(PostgresError) -> PostgresResult {
        do {
            return try await withConnection { connection in
                try connection.execute(sql)
            }
        } catch let error as PostgresError {
            throw error
        } catch {
            throw PostgresError.transportError(reason: "\(error)")
        }
    }

    public func query(_ statement: PostgresStatement) async throws(PostgresError) -> PostgresResult {
        do {
            return try await withConnection { connection in
                try connection.query(statement)
            }
        } catch let error as PostgresError {
            throw error
        } catch {
            throw PostgresError.transportError(reason: "\(error)")
        }
    }

    public func shutdown() {
        for worker in workers { worker.stop() }
        let parked = state.withLock { state -> [UnsafeContinuation<Int, Error>] in
            state.shuttingDown = true
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in parked { waiter.resume(throwing: PostgresError.poolShutdown) }
    }

    deinit {
        shutdown()
    }

    private func runLeased<Result: Sendable>(_ index: Int, _ body: @escaping @Sendable (PostgresLeasedConnection) throws -> Result) async throws -> Result {
        let worker = workers[index]
        return try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<Result, Error>) in
            let accepted = worker.submitJob {
                do {
                    continuation.resume(returning: try body(PostgresLeasedConnection(connection: worker.currentConnection)))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            if !accepted {
                continuation.resume(throwing: PostgresError.poolShutdown)
            }
        }
    }

    private enum Acquisition {

        case leased(Int)
        case parked
        case allDown
        case shuttingDown
    }

    private enum Release {

        case returnedToFreeList
        case handoff(UnsafeContinuation<Int, Error>)
    }

    private func acquire() async throws -> Int {
        if let index = state.withLock({ $0.free.popLast() }) {
            return index
        }
        return try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<Int, Error>) in
            resumeOrPark(continuation)
        }
    }

    private func resumeOrPark(_ continuation: UnsafeContinuation<Int, Error>) {
        switch claimOrEnqueue(continuation) {
        case .leased(let index): continuation.resume(returning: index)
        case .allDown: continuation.resume(throwing: PostgresError.allConnectionsDown)
        case .shuttingDown: continuation.resume(throwing: PostgresError.poolShutdown)
        case .parked: break
        }
    }

    private func claimOrEnqueue(_ continuation: UnsafeContinuation<Int, Error>) -> Acquisition {
        state.withLock {
            if $0.shuttingDown { return .shuttingDown }
            if let index = $0.free.popLast() { return .leased(index) }
            if $0.healthyCount == 0 { return .allDown }
            $0.waiters.append(continuation)
            return .parked
        }
    }

    private func release(_ index: Int) {
        let outcome: Release = state.withLock {
            if $0.waiters.isEmpty {
                $0.free.append(index)
                return .returnedToFreeList
            }
            return .handoff($0.waiters.removeFirst())
        }
        if case .handoff(let waiter) = outcome { waiter.resume(returning: index) }
    }

    private func finishLease(_ index: Int, _ error: Error) {
        guard PostgresError.translate(error).isConnectionFatal else {
            release(index)
            return
        }
        markDown(index)
    }

    private func markDown(_ index: Int) {
        let stranded = state.withLock { state -> [UnsafeContinuation<Int, Error>] in
            state.healthyCount -= 1
            guard state.healthyCount == 0, !state.shuttingDown else { return [] }
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in stranded { waiter.resume(throwing: PostgresError.allConnectionsDown) }
        logger.warning("postgres connection lost; reconnecting in the background", metadata: ["slot": "\(index)"])
        startReconnect(index)
    }

    private func startReconnect(_ index: Int) {
        guard case .reconnectable(let target) = source else { return }
        let thread = Thread { [weak self] in
            var delaySeconds = Self.initialBackoffSeconds
            while !(self?.state.withLock { $0.shuttingDown } ?? true) {
                if let pool = self, let connection = try? target.connect() {
                    pool.workers[index].replaceConnection(connection)
                    pool.markRecovered(index)
                    pool.logger.notice("postgres connection recovered", metadata: ["slot": "\(index)"])
                    return
                }
                Thread.sleep(forTimeInterval: delaySeconds)
                delaySeconds = min(delaySeconds * 2, Self.maxBackoffSeconds)
            }
        }
        thread.stackSize = 1 << 20
        thread.start()
    }

    private func markRecovered(_ index: Int) {
        let outcome: Release = state.withLock {
            $0.healthyCount += 1
            if $0.waiters.isEmpty {
                $0.free.append(index)
                return .returnedToFreeList
            }
            return .handoff($0.waiters.removeFirst())
        }
        if case .handoff(let waiter) = outcome { waiter.resume(returning: index) }
    }
}

extension PostgresLeasePool: PostgresClient {}
