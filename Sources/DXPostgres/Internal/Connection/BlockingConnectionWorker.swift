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
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Owns one blocking connection and the single thread that drives it. Callers
// submit work from any task; the thread drains the whole pending queue per wake
// and runs each query back-to-back on its connection, resuming each waiter as the
// result lands. Three properties keep the async-to-sync hand-off lean: the queue
// is double-buffered so a drain swaps two arrays rather than copying the pending
// one (no per-batch allocation, no per-item retain); the wake is signalled only on
// the idle-to-busy transition, so a thread already draining is never woken
// redundantly; and the queue is guarded by a raw pthread mutex and condition
// variable, the bare POSIX primitive with no Foundation-wrapper overhead on the
// per-query submit/wait. Under load the thread does nothing but back-to-back
// round-trips.
//
// `@unchecked Sendable` is sound because all mutable state is guarded by the mutex,
// and the connection is only ever touched by the owning thread.
final class BlockingConnectionWorker: @unchecked Sendable {

    struct ScalarWork {

        let sql: String
        let value: Int64
        let continuation: UnsafeContinuation<Int64, Error>
    }

    private let connection: BlockingPostgresConnection
    private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    private let workAvailable = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)
    private var pendingScalar: [ScalarWork] = []
    private var drainScalar: [ScalarWork] = []
    private var stopped = false

    init(connection: BlockingPostgresConnection) {
        self.connection = connection
        pthread_mutex_init(mutex, nil)
        pthread_cond_init(workAvailable, nil)
        pendingScalar.reserveCapacity(1024)
        drainScalar.reserveCapacity(1024)
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.stackSize = 1 << 20
        thread.start()
    }

    func submitScalar(_ work: ScalarWork) -> Bool {
        pthread_mutex_lock(mutex)
        guard !stopped else {
            pthread_mutex_unlock(mutex)
            return false
        }
        let wasIdle = pendingScalar.isEmpty
        pendingScalar.append(work)
        if wasIdle { pthread_cond_signal(workAvailable) }
        pthread_mutex_unlock(mutex)
        return true
    }

    func stop() {
        pthread_mutex_lock(mutex)
        stopped = true
        pthread_cond_broadcast(workAvailable)
        pthread_mutex_unlock(mutex)
    }

    private func run() {
        while swapInPendingWork() {
            for work in drainScalar { executeScalar(work) }
            drainScalar.removeAll(keepingCapacity: true)
        }
        connection.close()
    }

    private func swapInPendingWork() -> Bool {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        waitForWorkOrStop()
        if pendingScalar.isEmpty { return false }
        swap(&pendingScalar, &drainScalar)
        return true
    }

    private func waitForWorkOrStop() {
        while pendingScalar.isEmpty && !stopped {
            pthread_cond_wait(workAvailable, mutex)
        }
    }

    private func executeScalar(_ work: ScalarWork) {
        do {
            let value = try connection.queryScalarInt64Inline(work.sql, value: work.value)
            work.continuation.resume(returning: value)
        } catch {
            work.continuation.resume(throwing: error)
        }
    }

    deinit {
        pthread_mutex_destroy(mutex)
        pthread_cond_destroy(workAvailable)
        mutex.deallocate()
        workAvailable.deallocate()
    }
}
