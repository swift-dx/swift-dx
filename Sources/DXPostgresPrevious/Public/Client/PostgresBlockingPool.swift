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

    public init(host: String, port: Int, username: String, password: String, database: String, applicationName: String, size: Int) throws(PostgresError) {
        var workers: [BlockingConnectionWorker] = []
        workers.reserveCapacity(size)
        for _ in 0..<max(1, size) {
            let connection = try BlockingPostgresConnection.connect(host: host, port: port, username: username, password: password, database: database, applicationName: applicationName)
            let worker = BlockingConnectionWorker(connection: connection)
            worker.start()
            workers.append(worker)
        }
        self.workers = workers
    }

    public func query(_ sql: String, binding parameters: [any PostgresEncodable]) async throws(PostgresError) -> PostgresQueryResult {
        let cells = try PostgresParameterEncoding.cells(from: parameters)
        let index = Int(cursor.wrappingAdd(1, ordering: .relaxed).oldValue % UInt64(workers.count))
        do {
            return try await withUnsafeThrowingContinuation { continuation in
                workers[index].submit(BlockingConnectionWorker.Work(sql: sql, parameters: cells, continuation: continuation))
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
