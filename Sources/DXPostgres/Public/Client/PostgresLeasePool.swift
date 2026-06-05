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

import Synchronization

/// A connection pool whose callers run synchronously in their own lane. A caller
/// leases a connection for the duration of a `withConnection` closure; the closure
/// runs on that connection's dedicated thread, where every query inside it executes
/// back-to-back with no per-query async hand-off, reaching the throughput of the
/// direct synchronous path. Only the lease itself is asynchronous: when every
/// connection is busy the caller suspends until one frees, so the async machinery
/// is paid exactly when callers outnumber connections and never per query.
///
/// `@unchecked Sendable` is sound because the free list and waiter queue are guarded
/// by the lock-held state and each connection is only ever touched on its own thread.
public final class PostgresLeasePool: @unchecked Sendable {

    private struct PoolState {

        var free: [Int]
        var waiters: [UnsafeContinuation<Int, Error>]
        var shuttingDown: Bool
    }

    private let workers: [LeaseWorker]
    private let state: Mutex<PoolState>

    public convenience init(host: String, port: Int, username: String, password: String, database: String, applicationName: String, size: Int) throws(PostgresError) {
        let count = max(1, size)
        var connections: [BlockingPostgresConnection] = []
        connections.reserveCapacity(count)
        for _ in 0..<count {
            connections.append(try BlockingPostgresConnection.connect(host: host, port: port, username: username, password: password, database: database, applicationName: applicationName))
        }
        self.init(connections: connections)
    }

    init(connections: [BlockingPostgresConnection]) {
        var workers: [LeaseWorker] = []
        workers.reserveCapacity(connections.count)
        for connection in connections {
            let worker = LeaseWorker(connection: connection)
            worker.start()
            workers.append(worker)
        }
        self.workers = workers
        self.state = Mutex(PoolState(free: Array(0..<workers.count), waiters: [], shuttingDown: false))
    }

    var waiterCount: Int {
        state.withLock { $0.waiters.count }
    }

    public func withConnection<Result: Sendable>(_ body: @escaping @Sendable (PostgresLeasedConnection) throws -> Result) async throws -> Result {
        let index = try await acquire()
        do {
            let result = try await runLeased(index, body)
            release(index)
            return result
        } catch {
            release(index)
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

    private func runLeased<Result: Sendable>(_ index: Int, _ body: @escaping @Sendable (PostgresLeasedConnection) throws -> Result) async throws -> Result {
        let worker = workers[index]
        return try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<Result, Error>) in
            let accepted = worker.submitJob {
                do {
                    continuation.resume(returning: try body(PostgresLeasedConnection(connection: worker.connection)))
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
        case .shuttingDown: continuation.resume(throwing: PostgresError.poolShutdown)
        case .parked: break
        }
    }

    private func claimOrEnqueue(_ continuation: UnsafeContinuation<Int, Error>) -> Acquisition {
        state.withLock {
            if $0.shuttingDown { return .shuttingDown }
            if let index = $0.free.popLast() { return .leased(index) }
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
}

extension PostgresLeasePool: PostgresClient {}
