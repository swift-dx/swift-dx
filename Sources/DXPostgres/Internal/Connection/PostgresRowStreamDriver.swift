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
import NIOConcurrencyHelpers

// Drives a streaming query: leases a connection, writes the query, and pulls
// backend messages one at a time, yielding each row into the async stream as it
// arrives so the full result set is never materialized at once. The leased
// connection is owned for the stream's lifetime and released exactly once.
//
// The single ownership rule is enforced by `claimConnection`: the producer's
// completion path and the stream's termination handler both call it, but only the
// first transitions the slot to `done` and receives the connection to dispose of.
// A connection drained cleanly to ReadyForQuery is returned to the pool for reuse;
// one abandoned mid-stream (consumer broke early, or an error) is closed, because
// its unread rows would desynchronize the protocol if it were reused. Closing the
// channel also unblocks a producer parked on the next message.
//
// `@unchecked Sendable` is sound because all mutable ownership state lives behind
// the lock-guarded box and the continuation is itself Sendable.
final class PostgresRowStreamDriver: @unchecked Sendable {

    private enum Slot {

        case pending
        case active(PostgresConnection)
        case done
    }

    private struct State {

        var terminated = false
        var slot: Slot = .pending
    }

    private let pool: PostgresConnectionPool
    private let write: @Sendable (PostgresConnection) throws -> Void
    private let continuation: AsyncThrowingStream<PostgresRow, Error>.Continuation
    private let state = NIOLockedValueBox(State())

    init(pool: PostgresConnectionPool, continuation: AsyncThrowingStream<PostgresRow, Error>.Continuation, write: @escaping @Sendable (PostgresConnection) throws -> Void) {
        self.pool = pool
        self.write = write
        self.continuation = continuation
    }

    func start() {
        Task { await run() }
    }

    func terminate() {
        guard case .found(let connection) = markTerminatedAndClaim() else { return }
        Task { await closeAndRelease(connection) }
    }

    private func run() async {
        do {
            let connection = try await pool.acquire()
            guard activate(connection) else { return await discard(connection) }
            try write(connection)
            try await pump(connection)
            await complete()
        } catch {
            await fail(error)
        }
    }

    private func pump(_ connection: PostgresConnection) async throws(PostgresError) {
        var columns: [PostgresColumn] = []
        var finished = false
        while !finished {
            finished = try await step(connection, columns: &columns)
        }
    }

    private func step(_ connection: PostgresConnection, columns: inout [PostgresColumn]) async throws(PostgresError) -> Bool {
        let message = try await connection.nextBackendMessage()
        switch message {
        case .rowDescription(let fields): columns = fields.map { PostgresColumn(field: $0) }; return false
        case .dataRow(let cells): continuation.yield(PostgresRow(columns: columns, cells: cells)); return false
        case .readyForQuery: return true
        case .error(let serverError): throw PostgresError.server(serverError)
        case .commandComplete, .emptyQueryResponse, .noData, .notice, .parameterStatus, .parseComplete, .bindComplete, .closeComplete, .parameterDescription, .copyInResponse, .portalSuspended, .backendKeyData, .notification: return false
        case .authentication: throw PostgresError.protocolError(reason: "unexpected authentication message during a streamed query")
        }
    }

    private func complete() async {
        if case .found(let connection) = claimConnection() {
            await pool.release(connection)
        }
        continuation.finish()
    }

    private func fail(_ error: Error) async {
        if case .found(let connection) = claimConnection() {
            await closeAndRelease(connection)
        }
        continuation.finish(throwing: Self.mapError(error))
    }

    private func discard(_ connection: PostgresConnection) async {
        await closeAndRelease(connection)
        continuation.finish(throwing: PostgresError.cancelled)
    }

    private func closeAndRelease(_ connection: PostgresConnection) async {
        await connection.close()
        await pool.release(connection)
    }

    private static func mapError(_ error: Error) -> PostgresError {
        (error as? PostgresError) ?? .transportError(reason: String(describing: error))
    }

    private func activate(_ connection: PostgresConnection) -> Bool {
        state.withLockedValue { state in
            guard !state.terminated else { return false }
            state.slot = .active(connection)
            return true
        }
    }

    private func claimConnection() -> Lookup<PostgresConnection> {
        state.withLockedValue { state in
            guard case .active(let connection) = state.slot else { return .notFound }
            state.slot = .done
            return .found(connection)
        }
    }

    private func markTerminatedAndClaim() -> Lookup<PostgresConnection> {
        state.withLockedValue { state in
            state.terminated = true
            guard case .active(let connection) = state.slot else { return .notFound }
            state.slot = .done
            return .found(connection)
        }
    }
}
