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

import Atomics
import NIOConcurrencyHelpers
import NIOCore

// One TCP (optionally TLS) connection to a PostgreSQL server, owning the NIO
// channel and the message stream it feeds. The pool leases a connection to one
// task at a time, so requests on a connection are strictly sequential: each
// writes its messages, then reads backend messages until ReadyForQuery. Every
// request is bounded by `requestTimeout`; when it elapses the channel is closed,
// which fails the in-flight read and surfaces `timedOut`.
//
// `@unchecked Sendable` is sound because the channel is event-loop pinned, the
// message stream is lock-guarded, and the closing flag lives behind a lock.
final class PostgresConnection: @unchecked Sendable {

    let channel: Channel
    let stream: PostgresMessageStream
    let openedAt: NIODeadline
    let requestTimeout: TimeAmount
    let connectTimeout: TimeAmount
    private let closing = NIOLockedValueBox(false)
    private let preparedStatements = NIOLockedValueBox(PreparedStatementCache())

    init(channel: Channel, stream: PostgresMessageStream, requestTimeout: TimeAmount, connectTimeout: TimeAmount) {
        self.channel = channel
        self.stream = stream
        self.openedAt = NIODeadline.now()
        self.requestTimeout = requestTimeout
        self.connectTimeout = connectTimeout
    }

    var isActive: Bool {
        guard !closing.withLockedValue({ $0 }) else { return false }
        return channel.isActive
    }

    func simpleQuery(_ sql: String) async throws(PostgresError) -> PostgresQueryResult {
        try await runRequest {
            self.beginSimpleQuery(sql)
            return try await self.collectResult()
        }
    }

    // Reuses a cached server-side prepared statement when this connection has
    // already parsed the same SQL, and drops the cache entry if the request fails
    // (a failed Parse leaves no usable statement behind).
    func extendedQuery(_ sql: String, parameters: [PostgresCell]) async throws(PostgresError) -> PostgresQueryResult {
        try await runRequest {
            try await self.runExtended(sql: sql, parameters: parameters)
        }
    }

    // Sends every parameter set for one SQL string in a single write, then reads
    // their results in order. Each statement carries its own Sync, so the server
    // runs them as independent autocommit statements and an error in one is
    // isolated to that result rather than discarding the batch. The whole batch
    // costs one network round-trip instead of one per statement, which is what lets
    // a pipelined insert outrun a client that waits for each row's acknowledgement.
    // collectResult drains each statement through its ReadyForQuery even on error,
    // so a mid-batch failure leaves the connection in sync for the next caller; the
    // first captured error is raised after the whole batch is drained.
    func pipelineExtended(sql: String, parameterSets: [[PostgresCell]]) async throws(PostgresError) -> [PostgresQueryResult] {
        try await runRequest {
            try await self.runPipeline(sql: sql, parameterSets: parameterSets)
        }
    }

    private func runPipeline(sql: String, parameterSets: [[PostgresCell]]) async throws(PostgresError) -> [PostgresQueryResult] {
        let plan = preparedStatements.withLockedValue { $0.plan(for: sql) }
        do {
            writePipeline(plan: plan, sql: sql, parameterSets: parameterSets)
            return try await collectPipeline(count: parameterSets.count)
        } catch {
            preparedStatements.withLockedValue { $0.evict(sql) }
            throw error
        }
    }

    private func writePipeline(plan: PreparedStatementCache.Plan, sql: String, parameterSets: [[PostgresCell]]) {
        let allocator = channel.allocator
        var buffer = allocator.buffer(capacity: 64 * parameterSets.count + 128)
        appendParseIfNeeded(plan: plan, sql: sql, into: &buffer, allocator: allocator)
        let statement = plan.statementName
        for parameters in parameterSets {
            appendMessage(FrontendMessage.bind(portalName: "", statementName: statement, parameters: parameters, allocator: allocator), to: &buffer)
            appendMessage(FrontendMessage.describePortal(name: "", allocator: allocator), to: &buffer)
            appendMessage(FrontendMessage.execute(portalName: "", maxRows: 0, allocator: allocator), to: &buffer)
            appendMessage(FrontendMessage.sync(allocator: allocator), to: &buffer)
        }
        write(buffer)
    }

    private func collectPipeline(count: Int) async throws(PostgresError) -> [PostgresQueryResult] {
        var results: [PostgresQueryResult] = []
        results.reserveCapacity(count)
        var captured = CapturedPipelineError.none
        for _ in 0..<count {
            do {
                results.append(try await collectResult())
            } catch let error {
                captured.captureFirst(error)
            }
        }
        try captured.throwIfPresent()
        return results
    }

    private func runExtended(sql: String, parameters: [PostgresCell]) async throws(PostgresError) -> PostgresQueryResult {
        let plan = preparedStatements.withLockedValue { $0.plan(for: sql) }
        do {
            writeExtendedQuery(plan: plan, sql: sql, parameters: parameters)
            return try await collectResult()
        } catch {
            return try await recoverExtended(error, plan: plan, sql: sql, parameters: parameters)
        }
    }

    // On any failure the cached statement is dropped. When the failure is a stale
    // prepared statement reused from the cache — PostgreSQL replans these, but
    // YugabyteDB invalidates the table object on TRUNCATE without replanning — the
    // statement is re-parsed and the query retried once on the same connection, so
    // the caller never sees the spurious error. The Sync that ended the failed
    // exchange already returned the connection to a usable state.
    private func recoverExtended(_ error: PostgresError, plan: PreparedStatementCache.Plan, sql: String, parameters: [PostgresCell]) async throws(PostgresError) -> PostgresQueryResult {
        preparedStatements.withLockedValue { $0.evict(sql) }
        guard Self.shouldReparse(error, plan: plan) else { throw error }
        let reparsed = preparedStatements.withLockedValue { $0.plan(for: sql) }
        writeExtendedQuery(plan: reparsed, sql: sql, parameters: parameters)
        return try await collectResult()
    }

    private static func shouldReparse(_ error: PostgresError, plan: PreparedStatementCache.Plan) -> Bool {
        guard case .prepared = plan, case .server(let serverError) = error else { return false }
        return indicatesStalePreparedStatement(serverError)
    }

    static func indicatesStalePreparedStatement(_ error: PostgresServerError) -> Bool {
        switch error.sqlState {
        case "26000", "0A000": return true
        case "XX000": return error.message.contains("does not exist")
        default: return false
        }
    }

    // Write-only query entry points. Streaming reads the backend messages itself,
    // one row at a time, instead of collecting them, so it drives the wire
    // through these and then pulls with nextBackendMessage. Streamed queries run
    // unnamed (ephemeral) rather than through the prepared-statement cache.
    func beginSimpleQuery(_ sql: String) {
        write(FrontendMessage.query(sql, allocator: channel.allocator))
    }

    func beginExtendedQuery(sql: String, parameters: [PostgresCell]) {
        writeExtendedQuery(plan: .ephemeral, sql: sql, parameters: parameters)
    }

    func write(_ buffer: ByteBuffer) {
        channel.writeAndFlush(buffer, promise: nil)
    }

    func nextBackendMessage() async throws(PostgresError) -> BackendMessage {
        try await PostgresError.bridge {
            try await self.stream.next()
        }
    }

    // Bulk-loads rows with COPY ... FROM STDIN in text format. Runs without the
    // per-request timeout (like streaming) because a bulk load can legitimately
    // run long; cancellation closes the connection. On a client-side encoding
    // failure it sends CopyFail and drains the server's response before rethrowing.
    func performCopyIn<Rows: Sequence>(sql: String, rows: Rows) async throws(PostgresError) -> Int where Rows.Element == [any PostgresEncodable] {
        beginSimpleQuery(sql)
        try await expectCopyInResponse()
        do {
            try sendCopyRows(rows)
        } catch {
            write(FrontendMessage.copyFail(message: "client-side row encoding failed", allocator: channel.allocator))
            _ = try? await collectResult()
            throw error
        }
        write(FrontendMessage.copyDone(allocator: channel.allocator))
        return try await collectResult().commandTag.affectedRows
    }

    private func expectCopyInResponse() async throws(PostgresError) {
        let message = try await nextBackendMessage()
        switch message {
        case .copyInResponse: return
        case .error(let serverError): throw PostgresError.server(serverError)
        default: throw PostgresError.protocolError(reason: "expected CopyInResponse to begin COPY, received another message")
        }
    }

    private func sendCopyRows<Rows: Sequence>(_ rows: Rows) throws(PostgresError) where Rows.Element == [any PostgresEncodable] {
        var payload = channel.allocator.buffer(capacity: 64 * 1024)
        for row in rows {
            payload.writeBytes(PostgresCopyTextEncoding.line(try PostgresParameterEncoding.cells(from: row)))
            flushCopyDataIfLarge(&payload)
        }
        flushCopyData(&payload)
    }

    private func flushCopyDataIfLarge(_ payload: inout ByteBuffer) {
        guard payload.readableBytes >= 32 * 1024 else { return }
        flushCopyData(&payload)
    }

    private func flushCopyData(_ payload: inout ByteBuffer) {
        guard payload.readableBytes > 0 else { return }
        write(FrontendMessage.copyData(payload: payload, allocator: channel.allocator))
        payload = channel.allocator.buffer(capacity: 64 * 1024)
    }

    private func writeExtendedQuery(plan: PreparedStatementCache.Plan, sql: String, parameters: [PostgresCell]) {
        let allocator = channel.allocator
        var buffer = allocator.buffer(capacity: 128)
        appendParseIfNeeded(plan: plan, sql: sql, into: &buffer, allocator: allocator)
        let statement = plan.statementName
        appendMessage(FrontendMessage.bind(portalName: "", statementName: statement, parameters: parameters, allocator: allocator), to: &buffer)
        appendMessage(FrontendMessage.describePortal(name: "", allocator: allocator), to: &buffer)
        appendMessage(FrontendMessage.execute(portalName: "", maxRows: 0, allocator: allocator), to: &buffer)
        appendMessage(FrontendMessage.sync(allocator: allocator), to: &buffer)
        write(buffer)
    }

    private func appendParseIfNeeded(plan: PreparedStatementCache.Plan, sql: String, into buffer: inout ByteBuffer, allocator: ByteBufferAllocator) {
        guard plan.needsParse else { return }
        appendMessage(FrontendMessage.parse(statementName: plan.statementName, sql: sql, allocator: allocator), to: &buffer)
    }

    private func appendMessage(_ message: ByteBuffer, to buffer: inout ByteBuffer) {
        var message = message
        buffer.writeBuffer(&message)
    }

    private func collectResult() async throws(PostgresError) -> PostgresQueryResult {
        var accumulator = ResultAccumulator()
        var finished = false
        while !finished {
            let message = try await nextBackendMessage()
            finished = try accumulator.absorb(message)
        }
        return try accumulator.result()
    }

    func runRequest<Value>(_ body: () async throws -> Value) async throws(PostgresError) -> Value {
        try await runBounded(timeout: requestTimeout, body)
    }

    // Runs an exchange under an explicit timeout. Queries use the per-request
    // timeout; the startup handshake uses the connect timeout instead, because the
    // SCRAM key derivation is CPU-heavy and must not be cut short by a tight
    // per-query budget.
    func runBounded<Value>(timeout: TimeAmount, _ body: () async throws -> Value) async throws(PostgresError) -> Value {
        let timedOut = ManagedAtomic<Bool>(false)
        let timer = channel.eventLoop.scheduleTask(in: timeout) {
            timedOut.store(true, ordering: .relaxed)
            self.closeImmediately()
        }
        return try await finishRequest(body, timeout: timer, timedOut: timedOut)
    }

    private func finishRequest<Value>(_ body: () async throws -> Value, timeout: Scheduled<Void>, timedOut: ManagedAtomic<Bool>) async throws(PostgresError) -> Value {
        do {
            let value = try await withTaskCancellationHandler(operation: body, onCancel: { self.closeImmediately() })
            timeout.cancel()
            return value
        } catch {
            timeout.cancel()
            throw Self.mapRequestError(error, timedOut: timedOut.load(ordering: .relaxed))
        }
    }

    private static func mapRequestError(_ error: Error, timedOut: Bool) -> PostgresError {
        if timedOut { return .timedOut }
        if let postgres = error as? PostgresError { return postgres }
        return .transportError(reason: String(describing: error))
    }

    private func closeImmediately() {
        closing.withLockedValue { $0 = true }
        channel.close(promise: nil)
    }

    func close() async {
        closing.withLockedValue { $0 = true }
        try? await channel.close().get()
    }
}
