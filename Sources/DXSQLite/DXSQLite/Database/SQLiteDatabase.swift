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

import NIOPosix

/// A long-lived, pooled handle to one SQLite database.
///
/// Open it once with ``SQLite/connect(_:)`` (or run it as a ServiceLifecycle
/// `Service`) and share the single instance for the process lifetime; it is
/// `Sendable` and every connection is reused, never reopened per call. Writes
/// go through ``write(_:)`` onto a single connection serialized on its own
/// thread — the only writer SQLite allows. Reads go through ``read(_:)`` onto a
/// bounded pool of read-only connections that, under WAL, run concurrently with
/// each other and with the writer. The blocking SQLite calls execute on
/// dedicated `NIOThreadPool` threads so they never block the cooperative pool.
public final class SQLiteDatabase: Sendable {

    let configuration: SQLiteConfiguration
    let writerConnection: SQLiteConnection
    let readerPool: SQLiteReaderPool
    let writerThreadPool: NIOThreadPool
    let readerThreadPool: NIOThreadPool

    init(configuration: SQLiteConfiguration, writerConnection: SQLiteConnection, readerPool: SQLiteReaderPool, writerThreadPool: NIOThreadPool, readerThreadPool: NIOThreadPool) {
        self.configuration = configuration
        self.writerConnection = writerConnection
        self.readerPool = readerPool
        self.writerThreadPool = writerThreadPool
        self.readerThreadPool = readerThreadPool
    }

    static func open(_ configuration: SQLiteConfiguration) throws(SQLiteError) -> SQLiteDatabase {
        let writerConnection = try SQLiteConnection.open(configuration.location, readOnly: false, customizations: configuration.customizations)
        try configureWriter(writerConnection, configuration: configuration)
        writerConnection.installAuthorizer(configuration.authorization)
        let readerCount = max(1, configuration.maxReaders)
        let writerThreadPool = NIOThreadPool(numberOfThreads: 1)
        writerThreadPool.start()
        let readerThreadPool = NIOThreadPool(numberOfThreads: readerCount)
        readerThreadPool.start()
        let readerPool = SQLiteReaderPool(location: configuration.location, maxReaders: readerCount, busyTimeoutMilliseconds: configuration.busyTimeoutMilliseconds, customizations: configuration.customizations)
        return SQLiteDatabase(configuration: configuration, writerConnection: writerConnection, readerPool: readerPool, writerThreadPool: writerThreadPool, readerThreadPool: readerThreadPool)
    }

    public func write<Value: Sendable>(_ body: @escaping @Sendable (SQLiteWriter) throws -> Value) async throws -> Value {
        let connection = writerConnection
        return try await writerThreadPool.runIfActive {
            try body(SQLiteWriter(connection: connection))
        }
    }

    public func transaction<Value: Sendable>(_ body: @escaping @Sendable (SQLiteWriter) throws -> Value) async throws -> Value {
        try await write { writer in
            try writer.transaction(body)
        }
    }

    public func read<Value: Sendable>(_ body: @escaping @Sendable (SQLiteReader) throws -> Value) async throws -> Value {
        let connection = try await readerPool.acquire()
        do {
            let value = try await readerThreadPool.runIfActive {
                try body(SQLiteReader(connection: connection))
            }
            await readerPool.release(connection)
            return value
        } catch {
            await readerPool.release(connection)
            throw error
        }
    }

    public func readStream(_ sql: String, parameters: [SQLiteValue] = []) -> AsyncThrowingStream<SQLiteRow, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.streamRows(sql, parameters, into: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamRows(_ sql: String, _ parameters: [SQLiteValue], into continuation: AsyncThrowingStream<SQLiteRow, any Error>.Continuation) async {
        let connection: SQLiteConnection
        do {
            connection = try await readerPool.acquire()
        } catch {
            continuation.finish(throwing: error)
            return
        }
        do {
            try await readerThreadPool.runIfActive {
                try connection.streamRows(sql, parameters) { row in
                    if case .terminated = continuation.yield(row) {
                        return false
                    }
                    return true
                }
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
        await readerPool.release(connection)
    }

    public func observeUpdates(_ handler: @escaping @Sendable (SQLiteChange) -> Void) async throws(SQLiteError) {
        let box = SQLiteUpdateHookBox(handler: handler)
        try await onWriter { $0.setUpdateHook(box) }
    }

    public func observeCommits(_ handler: @escaping @Sendable () -> Void) async throws(SQLiteError) {
        let box = SQLiteCommitHookBox(handler: handler)
        try await onWriter { $0.setCommitHook(box) }
    }

    public func observeRollbacks(_ handler: @escaping @Sendable () -> Void) async throws(SQLiteError) {
        let box = SQLiteRollbackHookBox(handler: handler)
        try await onWriter { $0.setRollbackHook(box) }
    }

    public func observeTrace(_ handler: @escaping @Sendable (String) -> Void) async throws(SQLiteError) {
        let box = SQLiteTraceBox(handler)
        try await onWriter { $0.setTrace(box) }
    }

    public func observeBusy(_ handler: @escaping @Sendable (Int) -> Bool) async throws(SQLiteError) {
        let box = SQLiteBusyBox(handler)
        try await onWriter { $0.setBusy(box) }
    }

    public func observeProgress(everyInstructions interval: Int, _ handler: @escaping @Sendable () -> Bool) async throws(SQLiteError) {
        let box = SQLiteProgressBox(handler)
        let step = Int32(max(1, interval))
        try await onWriter { $0.setProgress(box, instructionInterval: step) }
    }

    private func onWriter(_ body: @escaping @Sendable (SQLiteConnection) -> Void) async throws(SQLiteError) {
        let connection = writerConnection
        do {
            try await writerThreadPool.runIfActive { body(connection) }
        } catch {
            throw SQLiteError.databaseClosed
        }
    }

    public func close() async {
        await readerPool.shutdown()
        await shutDown(readerThreadPool)
        await shutDown(writerThreadPool)
        writerConnection.close()
    }

    private static func configureWriter(_ connection: SQLiteConnection, configuration: SQLiteConfiguration) throws(SQLiteError) {
        try connection.execute("PRAGMA journal_mode=WAL;")
        try connection.execute("PRAGMA busy_timeout=\(configuration.busyTimeoutMilliseconds);")
        try connection.execute("PRAGMA foreign_keys=ON;")
    }

    private func shutDown(_ pool: NIOThreadPool) async {
        await withCheckedContinuation { continuation in
            pool.shutdownGracefully { _ in continuation.resume() }
        }
    }
}
