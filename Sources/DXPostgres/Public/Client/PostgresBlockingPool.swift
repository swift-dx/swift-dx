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

/// Experimental connection pool whose wire I/O runs synchronously on one
/// dedicated thread per connection, behind an async facade. A connection is
/// strictly sequential, so blocking its owning thread on the socket costs nothing
/// the protocol does not already require; concurrency comes from running many
/// such connections and letting the async facade hold the waiting callers
/// cheaply. Each query is round-robined to a connection's thread and awaited.
///
/// `@unchecked Sendable` is sound because the workers are immutable after init and
/// each owns its own lock-guarded queue; the only shared mutable state is the
/// round-robin cursor, which is an atomic.
public final class PostgresBlockingPool: @unchecked Sendable {

    private let workers: [BlockingConnectionWorker]
    private let cursor = Atomic<UInt64>(0)

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
        var workers: [BlockingConnectionWorker] = []
        workers.reserveCapacity(connections.count)
        for connection in connections {
            let worker = BlockingConnectionWorker(connection: connection)
            worker.start()
            workers.append(worker)
        }
        self.workers = workers
    }

    public func queryScalarInt64(_ sql: String, value: Int64) async throws(PostgresError) -> Int64 {
        let index = Int(cursor.wrappingAdd(1, ordering: .relaxed).oldValue % UInt64(workers.count))
        do {
            return try await withUnsafeThrowingContinuation { continuation in
                let work = BlockingConnectionWorker.ScalarWork(sql: sql, value: value, continuation: continuation)
                if !workers[index].submitScalar(work) {
                    continuation.resume(throwing: PostgresError.poolShutdown)
                }
            }
        } catch let error as PostgresError {
            throw error
        } catch {
            throw PostgresError.transportError(reason: "\(error)")
        }
    }

    public func shutdown() {
        for worker in workers {
            worker.stop()
        }
    }
}
