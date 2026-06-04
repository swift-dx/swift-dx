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

// Owns one blocking connection and the dedicated thread that drives it, and runs
// whole leased closures on that thread rather than individual queries. A lease ships
// one job here; inside it the caller issues a run of synchronous queries that all
// execute on this thread back-to-back with no per-query hand-off, exactly as the
// direct synchronous path does. Blocking on the socket is safe because this thread
// is private to the connection and never a shared concurrency runtime thread. The
// job queue is guarded by a raw pthread mutex and condition variable rather than a
// Foundation wrapper, so the wait/signal on each lease boundary is the bare POSIX
// primitive with no class-instance or method-dispatch overhead.
//
// `@unchecked Sendable` is sound because the job queue is guarded by the mutex and
// the connection is only ever touched by this owning thread.
final class LeaseWorker: @unchecked Sendable {

    let connection: BlockingPostgresConnection
    private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    private let jobAvailable = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)
    private var pending: [@Sendable () -> Void] = []
    private var drain: [@Sendable () -> Void] = []
    private var stopped = false

    init(connection: BlockingPostgresConnection) {
        self.connection = connection
        pthread_mutex_init(mutex, nil)
        pthread_cond_init(jobAvailable, nil)
        pending.reserveCapacity(64)
        drain.reserveCapacity(64)
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.stackSize = 1 << 20
        thread.start()
    }

    func submitJob(_ job: @escaping @Sendable () -> Void) {
        pthread_mutex_lock(mutex)
        let wasIdle = pending.isEmpty
        pending.append(job)
        if wasIdle { pthread_cond_signal(jobAvailable) }
        pthread_mutex_unlock(mutex)
    }

    func stop() {
        pthread_mutex_lock(mutex)
        stopped = true
        pthread_cond_broadcast(jobAvailable)
        pthread_mutex_unlock(mutex)
    }

    private func run() {
        while swapInJobs() {
            for job in drain { job() }
            drain.removeAll(keepingCapacity: true)
        }
        connection.close()
    }

    private func swapInJobs() -> Bool {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        while pending.isEmpty && !stopped { pthread_cond_wait(jobAvailable, mutex) }
        if pending.isEmpty { return false }
        swap(&pending, &drain)
        return true
    }

    deinit {
        pthread_mutex_destroy(mutex)
        pthread_cond_destroy(jobAvailable)
        mutex.deallocate()
        jobAvailable.deallocate()
    }
}
