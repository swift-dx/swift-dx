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
import Synchronization
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
// `@unchecked Sendable` is sound because the job queue is guarded by the mutex,
// and the connection reference is held in a Mutex box so the pool's reconnect
// thread can swap in a fresh connection after the old one dies while the owning
// thread is parked between leases. Each leased job reads the current connection
// once at its start through that box; every query inside the lease then runs on
// the captured reference with no further synchronization.
final class LeaseWorker: @unchecked Sendable {

    private let connectionBox: Mutex<BlockingPostgresConnection>
    private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    private let jobAvailable = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)
    private var pending: [@Sendable () -> Void] = []
    private var drain: [@Sendable () -> Void] = []
    private var stopped = false

    init(connection: BlockingPostgresConnection) {
        self.connectionBox = Mutex(connection)
        pthread_mutex_init(mutex, nil)
        pthread_cond_init(jobAvailable, nil)
        pending.reserveCapacity(64)
        drain.reserveCapacity(64)
    }

    var currentConnection: BlockingPostgresConnection {
        connectionBox.withLock { $0 }
    }

    func replaceConnection(_ connection: BlockingPostgresConnection) {
        let previous = connectionBox.withLock { box -> BlockingPostgresConnection in
            let previous = box
            box = connection
            return previous
        }
        previous.close()
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.stackSize = 1 << 20
        thread.start()
    }

    func submitJob(_ job: @escaping @Sendable () -> Void) -> Bool {
        pthread_mutex_lock(mutex)
        guard !stopped else {
            pthread_mutex_unlock(mutex)
            return false
        }
        let wasIdle = pending.isEmpty
        pending.append(job)
        if wasIdle { pthread_cond_signal(jobAvailable) }
        pthread_mutex_unlock(mutex)
        return true
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
        currentConnection.close()
    }

    private func swapInJobs() -> Bool {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        waitForJobOrStop()
        if pending.isEmpty { return false }
        swap(&pending, &drain)
        return true
    }

    private func waitForJobOrStop() {
        while pending.isEmpty && !stopped { pthread_cond_wait(jobAvailable, mutex) }
    }

    deinit {
        pthread_mutex_destroy(mutex)
        pthread_cond_destroy(jobAvailable)
        mutex.deallocate()
        jobAvailable.deallocate()
    }
}
