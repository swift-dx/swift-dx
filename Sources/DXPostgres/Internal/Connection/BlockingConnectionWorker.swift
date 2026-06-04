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

import DXCore
import Foundation
import NIOCore

// Owns one blocking connection and the single thread that drives it. Callers
// submit work from any task; the thread drains the whole pending queue per wake
// and runs each query back-to-back on its connection, resuming each waiter as the
// result lands. Draining in batches means the lock and the wake are paid once per
// burst rather than once per query, so under load the thread does nothing but
// back-to-back round-trips — the property that lets a serial blocking connection
// reach the same throughput as the synchronous C client.
//
// `@unchecked Sendable` is sound because all mutable state is guarded by the
// condition's lock, and the connection is only ever touched by the owning thread.
final class BlockingConnectionWorker: @unchecked Sendable {

    struct Work {

        let sql: String
        let parameters: [PostgresCell]
        let continuation: UnsafeContinuation<PostgresQueryResult, Error>
    }

    private let connection: BlockingPostgresConnection
    private let condition = NSCondition()
    private var pending: [Work] = []
    private var stopped = false

    init(connection: BlockingPostgresConnection) {
        self.connection = connection
        pending.reserveCapacity(1024)
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.stackSize = 1 << 20
        thread.start()
    }

    func submit(_ work: Work) {
        condition.lock()
        pending.append(work)
        condition.signal()
        condition.unlock()
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }

    private func run() {
        while case .found(let batch) = waitForBatch() {
            for work in batch {
                execute(work)
            }
        }
        connection.close()
    }

    private func waitForBatch() -> Lookup<[Work]> {
        condition.lock()
        defer { condition.unlock() }
        while shouldKeepWaiting() {
            condition.wait()
        }
        guard !pending.isEmpty else { return .notFound }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        return .found(batch)
    }

    private func shouldKeepWaiting() -> Bool {
        pending.isEmpty && !stopped
    }

    private func execute(_ work: Work) {
        do {
            let result = try connection.query(work.sql, parameters: work.parameters)
            work.continuation.resume(returning: result)
        } catch {
            work.continuation.resume(throwing: error)
        }
    }
}
