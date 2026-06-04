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
        var waiters: [UnsafeContinuation<Int, Never>]
    }

    private let workers: [LeaseWorker]
    private let state: Mutex<PoolState>

    public init(host: String, port: Int, username: String, password: String, database: String, applicationName: String, size: Int) throws(PostgresError) {
        let count = max(1, size)
        var workers: [LeaseWorker] = []
        workers.reserveCapacity(count)
        for _ in 0..<count {
            let connection = try BlockingPostgresConnection.connect(host: host, port: port, username: username, password: password, database: database, applicationName: applicationName)
            let worker = LeaseWorker(connection: connection)
            worker.start()
            workers.append(worker)
        }
        self.workers = workers
        self.state = Mutex(PoolState(free: Array(0..<count), waiters: []))
    }

    public func withConnection<Result: Sendable>(_ body: @escaping @Sendable (PostgresLeasedConnection) throws -> Result) async throws -> Result {
        let index = await acquire()
        do {
            let result = try await runLeased(index, body)
            release(index)
            return result
        } catch {
            release(index)
            throw error
        }
    }

    public func shutdown() {
        for worker in workers { worker.stop() }
    }

    private func runLeased<Result: Sendable>(_ index: Int, _ body: @escaping @Sendable (PostgresLeasedConnection) throws -> Result) async throws -> Result {
        let worker = workers[index]
        return try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<Result, Error>) in
            worker.submitJob {
                do {
                    continuation.resume(returning: try body(PostgresLeasedConnection(connection: worker.connection)))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func acquire() async -> Int {
        if let index = state.withLock({ $0.free.popLast() }) {
            return index
        }
        return await withUnsafeContinuation { continuation in
            let ready: Int? = state.withLock {
                if let index = $0.free.popLast() { return index }
                $0.waiters.append(continuation)
                return nil
            }
            if let index = ready { continuation.resume(returning: index) }
        }
    }

    private func release(_ index: Int) {
        let waiter: UnsafeContinuation<Int, Never>? = state.withLock {
            if $0.waiters.isEmpty {
                $0.free.append(index)
                return nil
            }
            return $0.waiters.removeFirst()
        }
        waiter?.resume(returning: index)
    }
}
