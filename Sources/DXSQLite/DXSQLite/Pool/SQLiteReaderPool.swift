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

// Bounded pool of read-only connections. WAL lets readers run concurrently with
// each other and with the single writer, but each reader needs its own
// connection. The pool opens connections lazily up to maxReaders and reuses idle
// ones. When all are checked out, acquire suspends the caller on a FIFO waiter
// queue rather than failing; a release hands the connection straight to the
// longest-waiting caller. Waiters are resumed with databaseClosed on shutdown,
// and with CancellationError if the awaiting task is cancelled while parked, so
// a cancelled read never strands a caller waiting for a connection it will
// never receive.
actor SQLiteReaderPool {

    private struct Waiter {

        let id: Int
        let continuation: CheckedContinuation<SQLiteConnection, any Error>
    }

    private let location: SQLiteLocation
    private let maxReaders: Int
    private let busyTimeoutMilliseconds: Int
    private let customizations: SQLiteConnectionCustomizations
    private var idle: [SQLiteConnection] = []
    private var inUseCount = 0
    private var waiters: [Waiter] = []
    private var nextWaiterID = 0
    private var isShutdown = false

    init(location: SQLiteLocation, maxReaders: Int, busyTimeoutMilliseconds: Int, customizations: SQLiteConnectionCustomizations) {
        self.location = location
        self.maxReaders = maxReaders
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
        self.customizations = customizations
    }

    func acquire() async throws -> SQLiteConnection {
        guard !isShutdown else { throw SQLiteError.databaseClosed }
        switch takeIdle() {
        case .found(let connection): return connection
        case .notFound: return try await openOrWait()
        }
    }

    func release(_ connection: SQLiteConnection) {
        guard !isShutdown else {
            connection.close()
            return
        }
        guard !waiters.isEmpty else {
            inUseCount -= 1
            idle.append(connection)
            return
        }
        let waiter = waiters.removeFirst()
        waiter.continuation.resume(returning: connection)
    }

    func shutdown() {
        isShutdown = true
        let pending = waiters
        waiters.removeAll()
        for connection in idle {
            connection.close()
        }
        idle.removeAll()
        inUseCount = 0
        for waiter in pending {
            waiter.continuation.resume(throwing: SQLiteError.databaseClosed)
        }
    }

    private func openOrWait() async throws -> SQLiteConnection {
        guard inUseCount < maxReaders else { return try await waitForConnection() }
        return try openTracked()
    }

    private func waitForConnection() async throws -> SQLiteConnection {
        let id = nextWaiterID
        nextWaiterID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueueWaiter(id: id, continuation: continuation)
            }
        } onCancel: {
            Task { await self.removeWaiter(id) }
        }
    }

    private func enqueueWaiter(id: Int, continuation: CheckedContinuation<SQLiteConnection, any Error>) {
        guard !isShutdown else {
            continuation.resume(throwing: SQLiteError.databaseClosed)
            return
        }
        guard !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        grantOrPark(id: id, continuation: continuation)
    }

    private func grantOrPark(id: Int, continuation: CheckedContinuation<SQLiteConnection, any Error>) {
        switch takeIdle() {
        case .found(let connection): continuation.resume(returning: connection)
        case .notFound: openOrPark(id: id, continuation: continuation)
        }
    }

    private func openOrPark(id: Int, continuation: CheckedContinuation<SQLiteConnection, any Error>) {
        guard inUseCount < maxReaders else {
            waiters.append(Waiter(id: id, continuation: continuation))
            return
        }
        resumeWithNewConnection(continuation)
    }

    private func resumeWithNewConnection(_ continuation: CheckedContinuation<SQLiteConnection, any Error>) {
        do {
            continuation.resume(returning: try openTracked())
        } catch {
            continuation.resume(throwing: error)
        }
    }

    private func removeWaiter(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func takeIdle() -> Lookup<SQLiteConnection> {
        guard let connection = idle.popLast() else { return .notFound }
        inUseCount += 1
        return .found(connection)
    }

    private func openTracked() throws -> SQLiteConnection {
        let connection = try openReader()
        inUseCount += 1
        return connection
    }

    private func openReader() throws(SQLiteError) -> SQLiteConnection {
        let connection = try SQLiteConnection.open(location, readOnly: true, customizations: customizations)
        try connection.execute("PRAGMA busy_timeout=\(busyTimeoutMilliseconds);")
        connection.installAuthorizer(customizations.authorization)
        return connection
    }
}
