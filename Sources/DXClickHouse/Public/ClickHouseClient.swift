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

import Dispatch
import Foundation

// Typed Codable façade over a single raw POSIX-socket ClickHouse
// connection. The actor owns its worker DispatchQueue and serialises
// every wire round-trip through it, so concurrent callers from
// different async contexts share the connection safely.
//
// Three operations:
//
//   * `select<T>(_:as:settings:parameters:)` runs a SELECT and yields
//     each decoded row through an `AsyncThrowingStream<T,
//     ClickHouseError>`. Each block on the wire is parsed into typed
//     columns in one shot, then each row is decoded via the columnar
//     Codable decoder and yielded individually.
//
//   * `insert<T>(into:rows:)` flushes an array of Encodable rows to
//     the named table. The encoder builds columnar buffers, the block
//     writer turns them into a single Data packet, and the INSERT
//     handshake runs end-to-end. Returns a summary with rows-sent,
//     blocks-sent (always 1 for the array overload), and the server's
//     reported written-rows / written-bytes counters.
//
//   * `scalar<T>(_:as:)` runs a SELECT expected to return one row +
//     one column, decodes the column to `T`, and returns it. Throws if
//     the result shape is not exactly 1×1 or if the column type does
//     not match `T`.
public final actor ClickHouseClient {

    private let worker: DispatchQueue
    private let transport: ClientTransportBox

    nonisolated var workerForOverloads: DispatchQueue { worker }
    nonisolated var transportForOverloads: ClientTransportBox { transport }

    public init(
        host: String,
        port: Int,
        user: String = "default",
        password: String = "",
        database: String = "default"
    ) async throws(ClickHouseError) {
        let worker = DispatchQueue(label: "swift-dx.raw-clickhouse-client", qos: .userInitiated)
        self.worker = worker
        let connection: ClickHouseConnection = try await Self.openConnection(
            on: worker,
            host: host,
            port: port,
            user: user,
            password: password,
            database: database
        )
        self.transport = ClientTransportBox(connection: connection)
    }

    // Configuration-driven init. Both the ad-hoc `ClickHouse.connect`
    // path and the long-running `ClickHouseService` route through this
    // path so the on-the-wire behaviour is identical regardless of which
    // entry point the caller picks. A single-connection client targets
    // the first endpoint in the configuration; multi-endpoint failover
    // is the responsibility of the pool layer.
    public init(configuration: ClickHouseConfiguration) async throws(ClickHouseError) {
        let endpoint = configuration.endpoints[0]
        try await self.init(
            host: endpoint.host,
            port: endpoint.port,
            user: configuration.user,
            password: configuration.password,
            database: configuration.database
        )
    }

    deinit {
        // A client dropped without an explicit close() must not leak its worker
        // thread: if that worker is looping in the unbounded reconnect backoff
        // against a gone server, nothing else will ever stop it, keeping the
        // thread (and the process) alive forever. Signalling shutdown here makes
        // the reconnect loop break at its next wake. requestShutdown only stores
        // an atomic, so it is safe from a nonisolated deinit and does not disturb
        // an in-flight recv (it never shuts the socket).
        transport.connection.requestShutdown()
    }

    public func close() async {
        let transport = self.transport
        // Set shutdown BEFORE hopping onto the worker: if the worker is currently
        // spinning in the reconnect backoff loop, a requestShutdown enqueued
        // behind it would never run, so close() would hang. Storing the atomic
        // here breaks that loop so the queued teardown can proceed.
        transport.connection.requestShutdown()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            worker.async {
                transport.connection.close()
                continuation.resume()
            }
        }
    }

    // Bounded close for deadline-driven shutdown. `close()` enqueues the
    // teardown behind the serial worker, so it cannot complete while an
    // in-flight operation is parked in a blocking recv/send. This shuts
    // the socket down from the caller's thread first, which unblocks that
    // operation (it fails fast without reconnecting), letting the queued
    // close run. Use `close()` for graceful drain, this when a deadline
    // must be honored regardless of stuck work.
    public func forceClose() async {
        transport.connection.shutdownSocketForTimeout()
        await close()
    }

    // Returns an AsyncThrowingStream that yields one decoded `T` per
    // result row. The stream's declared failure type is `any Error`
    // because the standard library's `AsyncThrowingStream` does not yet
    // support a custom typed-failure parameter; every error this stream
    // surfaces is in fact a `ClickHouseError` and downstream callers
    // can downcast with `as` against the typed enum.
    //
    // Single-flight per connection: this backpressured stream holds the one
    // connection across its per-block reads, so a client must finish consuming
    // (or drop) the stream before issuing another query on the same client. A
    // second query started while a stream is in flight is rejected with a clear
    // `client.concurrentQuery` error rather than interleaving on the shared
    // connection. For concurrent reads use the collecting `selectAll` / `query`
    // (each runs to completion in one hop and is safe to call concurrently), or
    // open one client per concurrent stream.
    public nonisolated func select<T: Decodable & Sendable>(
        _ sql: String,
        as type: T.Type,
        settings: ClickHouseQuerySettings = .empty,
        parameters: ClickHouseQueryParameters = .empty
    ) -> AsyncThrowingStream<T, Error> {
        makeSelectStream(sql, settings: settings, parameters: parameters) { block, body in
            let typed = try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: body)
            return try ClickHouseCodableDecoder.decodeRows(type: T.self, columns: typed, rowCount: block.rowCount)
        }
    }

    // The columnar fast path: identical streaming, but each block is decoded
    // through ClickHouseRowDecodable's cursor instead of Codable, avoiding the
    // per-row keyed-container allocation. Use for large result sets where read
    // throughput matters; the Codable `select` stays for ergonomic decoding.
    //
    // Single-flight per connection, the same as `select`: finish or drop the
    // stream before the next query on this client, and use `selectAllFast` (or a
    // client per stream) for concurrent reads.
    public nonisolated func selectFast<T: ClickHouseRowDecodable & Sendable>(
        _ sql: String,
        as type: T.Type,
        settings: ClickHouseQuerySettings = .empty,
        parameters: ClickHouseQueryParameters = .empty
    ) -> AsyncThrowingStream<T, Error> {
        makeSelectStream(sql, settings: settings, parameters: parameters) { block, body in
            let typed = try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: body)
            return try ClickHouseCodableDecoder.decodeFastRows(type: T.self, columns: typed, rowCount: block.rowCount)
        }
    }

    private nonisolated func makeSelectStream<T: Sendable>(
        _ sql: String,
        settings: ClickHouseQuerySettings,
        parameters: ClickHouseQueryParameters,
        decode: @escaping @Sendable (ClickHouseBlock, UnsafeRawBufferPointer) throws -> [T]
    ) -> AsyncThrowingStream<T, Error> {
        // Backpressured: one result block is read from the connection each time
        // the consumer drains the buffered rows, so a slow consumer bounds memory
        // to a single block instead of accumulating the whole result. The state
        // object reads the connection lazily through `next()`; the unfolding
        // closure maps its `Step` onto the standard-library end-of-sequence
        // signal here, the single place an optional is involved.
        let state = ClickHouseSelectStreamState(
            worker: self.worker,
            transport: self.transport,
            sql: sql,
            settings: settings,
            parameters: parameters,
            decode: decode
        )
        return AsyncThrowingStream(unfolding: {
            switch try await state.next() {
            case .row(let row): return row
            case .end: return nil
            }
        })
    }

    // Materialises a full result through the columnar fast path without the
    // per-row AsyncThrowingStream hop: blocks are decoded and accumulated on
    // the worker, then the whole array is returned once. For a million-row
    // collect this avoids a million continuation yields and awaits, which
    // otherwise dominate over the decode itself.
    func collectFast<T: ClickHouseRowDecodable & Sendable>(
        sql: String,
        settings: ClickHouseQuerySettings,
        parameters: ClickHouseQueryParameters
    ) async throws(ClickHouseError) -> [T] {
        return try await runOnWorker { (transport: ClientTransportBox) throws(ClickHouseError) -> [T] in
            try Self.requireNoStreamInFlight(transport)
            try transport.connection.sendQuery(sql, queryID: "", settings: settings, parameters: parameters)
            var rows: [T] = []
            var outcome = StreamDecodeOutcome.ok
            _ = try transport.connection.receiveBlocks { block, body in
                if block.rowCount == 0 { return }
                if case .failed = outcome { return }
                do {
                    let typed = try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: body)
                    rows.append(contentsOf: try ClickHouseCodableDecoder.decodeFastRows(type: T.self, columns: typed, rowCount: block.rowCount))
                } catch let error as ClickHouseError {
                    outcome = .failed(error)
                } catch {
                    outcome = .failed(.protocolError(stage: "selectAllFast", message: "\(error)"))
                }
            }
            if case .failed(let error) = outcome { throw error }
            return rows
        }
    }

    // The fused fast read: blocks are parsed and decoded in a single pass on
    // the worker with no intermediate typed-column arrays, the lowest-overhead
    // read path.
    func collectFused<T: ClickHouseFusedDecodable & Sendable>(
        sql: String,
        settings: ClickHouseQuerySettings,
        parameters: ClickHouseQueryParameters
    ) async throws(ClickHouseError) -> [T] {
        try await runOnWorker { (transport: ClientTransportBox) throws(ClickHouseError) -> [T] in
            try Self.requireNoStreamInFlight(transport)
            try transport.connection.sendQuery(sql, queryID: "", settings: settings, parameters: parameters)
            var rows: [T] = []
            var outcome = StreamDecodeOutcome.ok
            _ = try transport.connection.receiveBlocks { block, body in
                if block.rowCount == 0 { return }
                if case .failed = outcome { return }
                do {
                    rows.append(contentsOf: try ClickHouseCodableDecoder.decodeFusedRows(type: T.self, block: block, body: body))
                } catch let error as ClickHouseError {
                    outcome = .failed(error)
                } catch {
                    outcome = .failed(.protocolError(stage: "selectAllFused", message: "\(error)"))
                }
            }
            if case .failed(let error) = outcome { throw error }
            return rows
        }
    }

    // A collecting query may not start while a backpressured stream still holds
    // the single connection mid-result; its send would interleave on the shared
    // wire and cross-talk. Reject it with a clear error instead. Checked on the
    // serial worker, where queryActive is mutated, so the read is race-free.
    static func requireNoStreamInFlight(_ transport: ClientTransportBox) throws(ClickHouseError) {
        if transport.queryActive {
            throw .protocolError(
                stage: "client.concurrentQuery",
                message: "a result stream is still in flight on this connection; finish or drop it before issuing another query on the same client, or use one client per concurrent query."
            )
        }
    }

    // Collecting Codable read. The whole query — send, drain every block,
    // decode through Codable — runs inside one serial-worker dispatch, so a
    // query holds the single connection for its entire lifecycle. The
    // backpressured `select` stream spans one dispatch per consumed block, which
    // would let a second concurrent query's send interleave on the shared
    // connection between this query's blocks and cross-talk the responses; the
    // collecting convenience must not, so it stays single-dispatch.
    func collectCodable<T: Decodable & Sendable>(
        sql: String,
        settings: ClickHouseQuerySettings,
        parameters: ClickHouseQueryParameters
    ) async throws(ClickHouseError) -> [T] {
        try await runOnWorker { (transport: ClientTransportBox) throws(ClickHouseError) -> [T] in
            try Self.requireNoStreamInFlight(transport)
            try transport.connection.sendQuery(sql, queryID: "", settings: settings, parameters: parameters)
            var rows: [T] = []
            var outcome = StreamDecodeOutcome.ok
            _ = try transport.connection.receiveBlocks { block, body in
                if block.rowCount == 0 { return }
                if case .failed = outcome { return }
                do {
                    let typed = try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: body)
                    rows.append(contentsOf: try ClickHouseCodableDecoder.decodeRows(type: T.self, columns: typed, rowCount: block.rowCount))
                } catch let error as ClickHouseError {
                    outcome = .failed(error)
                } catch {
                    outcome = .failed(.protocolError(stage: "selectAll", message: "\(error)"))
                }
            }
            if case .failed(let error) = outcome { throw error }
            return rows
        }
    }

    // Runs an arbitrary query and materialises every result block into a
    // ClickHouseQueryResult, read column-by-column with no Codable type. The
    // thinnest typed read path: parse the blocks, hand back the columns.
    func collectQuery(
        sql: String,
        settings: ClickHouseQuerySettings,
        parameters: ClickHouseQueryParameters
    ) async throws(ClickHouseError) -> ClickHouseQueryResult {
        try await runOnWorker { (transport: ClientTransportBox) throws(ClickHouseError) -> ClickHouseQueryResult in
            try Self.requireNoStreamInFlight(transport)
            try transport.connection.sendQuery(sql, queryID: "", settings: settings, parameters: parameters)
            var blocks: [[ClickHouseTypedColumn]] = []
            var blockOffsets: [Int] = [0]
            var total = 0
            var names: [String] = []
            var types: [String] = []
            var outcome = StreamDecodeOutcome.ok
            _ = try transport.connection.receiveBlocks { block, body in
                if names.isEmpty { names = block.columnNames; types = block.columnTypes }
                if block.rowCount == 0 { return }
                if case .failed = outcome { return }
                do {
                    let typed = try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: body)
                    blocks.append(typed.map(\.column))
                    total += block.rowCount
                    blockOffsets.append(total)
                } catch let error as ClickHouseError {
                    outcome = .failed(error)
                } catch {
                    outcome = .failed(.protocolError(stage: "query", message: "\(error)"))
                }
            }
            if case .failed(let error) = outcome { throw error }
            return ClickHouseQueryResult(columnNames: names, columnTypes: types, rowCount: total, blocks: blocks, blockOffsets: blockOffsets)
        }
    }

    func insertCore<T: Encodable & Sendable>(
        into table: String,
        rows: [T],
        settings: ClickHouseQuerySettings
    ) async throws(ClickHouseError) -> ClickHouseInsertSummary {
        if rows.isEmpty {
            return ClickHouseInsertSummary(rowsSent: 0, blocksSent: 0, writtenRows: 0, writtenBytes: 0)
        }
        let columns = try ClickHouseRowEncoder().encode(rows)
        return try await insertEncodedColumns(into: table, columns: columns, rowCount: rows.count, settings: settings)
    }

    // Columnar fast-path INSERT: encode the whole batch column-by-column with
    // no per-row Codable container, then share the same wire send as insertCore.
    func insertFastCore<T: ClickHouseColumnarEncodable & Sendable>(
        into table: String,
        rows: [T],
        settings: ClickHouseQuerySettings
    ) async throws(ClickHouseError) -> ClickHouseInsertSummary {
        if rows.isEmpty {
            return ClickHouseInsertSummary(rowsSent: 0, blocksSent: 0, writtenRows: 0, writtenBytes: 0)
        }
        var sink = ClickHouseColumnSink()
        T.encodeColumnar(rows, into: &sink)
        return try await insertEncodedColumns(into: table, columns: sink.columns, rowCount: rows.count, settings: settings)
    }

    private func insertEncodedColumns(
        into table: String,
        columns: [ClickHouseNamedColumn],
        rowCount: Int,
        settings: ClickHouseQuerySettings
    ) async throws(ClickHouseError) -> ClickHouseInsertSummary {
        let columnList = Self.makeColumnList(columns: columns)
        let sampleQuery = "INSERT INTO \(table) \(columnList) FORMAT Native"
        let revision = currentRevision()
        let dataPacket = try ClickHouseBlockWriter.encodeDataPacketTerminated(columns: columns, revision: revision)
        let terminator = ClickHouseBlockWriter.encodeEmptyDataPacket()
        let writtenCounters = try await runOnWorker { (transport: ClientTransportBox) throws(ClickHouseError) -> (UInt64, UInt64) in
            try Self.requireNoStreamInFlight(transport)
            try transport.connection.sendQuery(sampleQuery, queryID: "", settings: settings, parameters: .empty)
            let schema = try transport.connection.receiveInsertSampleSchema()
            try Self.validateInsertSchemaOrRecover(
                transport: transport,
                declared: columns,
                sampleSchema: schema,
                terminator: terminator
            )
            try transport.connection.sendRawBytes(dataPacket)
            return try transport.connection.receiveEndOfStream()
        }
        return ClickHouseInsertSummary(
            rowsSent: rowCount,
            blocksSent: 1,
            writtenRows: writtenCounters.0,
            writtenBytes: writtenCounters.1
        )
    }

    func insertNativeBlockCore(
        into table: String,
        columnList: String,
        nativeBlockBytes: [UInt8],
        settings: ClickHouseQuerySettings
    ) async throws(ClickHouseError) -> ClickHouseInsertSummary {
        let terminator = ClickHouseBlockWriter.encodeEmptyDataPacket()
        let writtenCounters = try await runOnWorker { (transport: ClientTransportBox) throws(ClickHouseError) -> (UInt64, UInt64) in
            try Self.requireNoStreamInFlight(transport)
            try transport.connection.sendQuery("INSERT INTO \(table) \(columnList) FORMAT Native", queryID: "", settings: settings, parameters: .empty)
            _ = try transport.connection.receiveInsertSampleSchema()
            try transport.connection.sendRawBytes(nativeBlockBytes, then: terminator)
            return try transport.connection.receiveEndOfStream()
        }
        return ClickHouseInsertSummary(
            rowsSent: 0,
            blocksSent: 1,
            writtenRows: writtenCounters.0,
            writtenBytes: writtenCounters.1
        )
    }

    // Wraps SELECT in a way that synthesizes a single-key row decoder
    // for the value column. The query is expected to project exactly
    // one column, named anything; the wrapper decodes whichever column
    // appears in the first slot. Internal-only — public scalar()
    // surfaces sit in ClickHouseClient+Timeout.swift.
    nonisolated func selectScalarStream<T: Decodable & Sendable>(
        sql: String,
        type: T.Type,
        settings: ClickHouseQuerySettings,
        parameters: ClickHouseQueryParameters
    ) -> AsyncThrowingStream<T, Error> {
        let worker = self.worker
        let transport = self.transport
        return AsyncThrowingStream { continuation in
            // A cancelled consumer would otherwise leave the worker parked in
            // a blocking recv (a stalled server never sends EndOfStream),
            // hanging every later operation behind the serial worker queue —
            // including close(). Shutting the socket down from the
            // cancellation thread unblocks that recv so the worker fails fast.
            continuation.onTermination = { reason in
                if case .cancelled = reason {
                    transport.connection.shutdownSocketForTimeout()
                }
            }
            worker.async {
                var outcome = StreamDecodeOutcome.ok
                do {
                    try transport.connection.sendQuery(
                        sql,
                        queryID: "",
                        settings: settings,
                        parameters: parameters
                    )
                    // Drain to EndOfStream even on a decode failure so the
                    // connection stays usable for the next query.
                    _ = try transport.connection.receiveBlocks { block, body in
                        if block.rowCount == 0 { return }
                        if case .failed = outcome { return }
                        do {
                            try Self.yieldScalarRows(block: block, body: body, type: T.self, continuation: continuation)
                        } catch let error as ClickHouseError {
                            outcome = .failed(error)
                        } catch {
                            outcome = .failed(.protocolError(stage: "scalar", message: "\(error)"))
                        }
                    }
                    outcome.finish(continuation)
                } catch let error as ClickHouseError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: ClickHouseError.protocolError(stage: "scalar", message: "\(error)"))
                }
            }
        }
    }

    // A scalar is exactly one value: one column, one row. Reject a
    // multi-row block before decoding it, so a query that returns many rows
    // (a forgotten LIMIT or aggregation) fails fast instead of decoding and
    // buffering the whole result only to fail the single-row check after.
    private static func requireSingleCell(_ block: ClickHouseBlock) throws(ClickHouseError) {
        guard block.columnCount == 1 else {
            throw .protocolError(stage: "scalar", message: "expected one column, got \(block.columnCount)")
        }
        guard block.rowCount == 1 else {
            throw .protocolError(stage: "scalar", message: "scalar query returned a block with \(block.rowCount) rows; expected exactly one")
        }
    }

    private static func yieldScalarRows<T: Decodable & Sendable>(
        block: ClickHouseBlock,
        body: UnsafeRawBufferPointer,
        type: T.Type,
        continuation: AsyncThrowingStream<T, Error>.Continuation
    ) throws(ClickHouseError) {
        try Self.requireSingleCell(block)
        let typed = try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: body)
        let renamed = [ClickHouseNamedColumn(name: ScalarRowWrapper<T>.scalarKey, column: typed[0].column)]
        let rows = try ClickHouseCodableDecoder.decodeRows(
            type: ScalarRowWrapper<T>.self,
            columns: renamed,
            rowCount: block.rowCount
        )
        for row in rows { continuation.yield(row.value) }
    }

    private func currentRevision() -> UInt64 {
        transport.connection.negotiatedRevision
    }

    private func runOnWorker<Value: Sendable>(
        _ body: @escaping @Sendable (ClientTransportBox) throws(ClickHouseError) -> Value
    ) async throws(ClickHouseError) -> Value {
        let worker = self.worker
        let transport = self.transport
        let outcome: Result<Value, ClickHouseError> = await withCheckedContinuation { continuation in
            worker.async {
                do {
                    let value = try body(transport)
                    continuation.resume(returning: .success(value))
                } catch let error as ClickHouseError {
                    continuation.resume(returning: .failure(error))
                } catch {
                    continuation.resume(returning: .failure(.protocolError(stage: "client.runOnWorker", message: "\(error)")))
                }
            }
        }
        switch outcome {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    private static func openConnection(
        on worker: DispatchQueue,
        host: String,
        port: Int,
        user: String,
        password: String,
        database: String
    ) async throws(ClickHouseError) -> ClickHouseConnection {
        let outcome: Result<ClickHouseConnection, ClickHouseError> = await withCheckedContinuation { continuation in
            worker.async {
                do {
                    let made = try ClickHouseConnection(
                        host: host,
                        port: port,
                        user: user,
                        password: password,
                        database: database
                    )
                    continuation.resume(returning: .success(made))
                } catch let error as ClickHouseError {
                    continuation.resume(returning: .failure(error))
                } catch {
                    continuation.resume(returning: .failure(.connectionFailed(reason: "\(error)")))
                }
            }
        }
        switch outcome {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    static func makeColumnList(columns: [ClickHouseNamedColumn]) -> String {
        let quoted = columns.map { "`\(escapeBacktickIdentifier($0.name))`" }.joined(separator: ", ")
        return "(\(quoted))"
    }

    // Backslash-escapes a backtick or backslash inside a column name so the
    // backtick-quoted identifier in the generated INSERT statement stays
    // well-formed. Column names come from the row type's CodingKeys, which
    // can carry any string, and ClickHouse permits those characters in a
    // quoted identifier; without escaping a name like "a`b" would close the
    // quote early and make the statement unparseable. This mirrors
    // ClickHouse's own backQuote: ` -> \` and \ -> \\.
    static func escapeBacktickIdentifier(_ identifier: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(identifier.count + 2)
        for character in identifier {
            if needsBacktickEscape(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    private static func needsBacktickEscape(_ character: Character) -> Bool {
        character == "\\" || character == "`"
    }

    // The INSERT handshake has already put the server into "awaiting data"
    // after the sample schema arrives. If validation rejects the schema,
    // throwing here would abandon the server mid-INSERT and desync the
    // connection for the next operation. Complete the INSERT with no rows
    // first so the connection returns to a clean boundary, then surface the
    // schema error.
    private static func validateInsertSchemaOrRecover(
        transport: ClientTransportBox,
        declared: [ClickHouseNamedColumn],
        sampleSchema: [ClickHouseConnection.InsertSchemaColumn],
        terminator: [UInt8]
    ) throws(ClickHouseError) {
        do {
            try validateInsertSchema(declared: declared, sampleSchema: sampleSchema)
        } catch {
            recoverAbortedInsert(transport: transport, terminator: terminator)
            throw error
        }
    }

    // Best effort: drive the server back to EndOfStream by sending the
    // empty terminating block and draining the acknowledgement. If the
    // connection is already broken these fail and the pool or client
    // lifecycle discards it; either way the caller still receives the
    // schema error that triggered the recovery.
    private static func recoverAbortedInsert(transport: ClientTransportBox, terminator: [UInt8]) {
        try? transport.connection.sendRawBytes(terminator)
        _ = try? transport.connection.receiveEndOfStream()
    }

    private static func validateInsertSchema(
        declared: [ClickHouseNamedColumn],
        sampleSchema: [ClickHouseConnection.InsertSchemaColumn]
    ) throws(ClickHouseError) {
        if sampleSchema.count != declared.count {
            throw .protocolError(
                stage: "insert.schema",
                message: "destination table has \(sampleSchema.count) columns, encoder produced \(declared.count)"
            )
        }
        for (lhs, rhs) in zip(declared, sampleSchema) {
            try requireColumnNamesMatch(declared: lhs, expected: rhs)
        }
    }

    private static func requireColumnNamesMatch(
        declared: ClickHouseNamedColumn,
        expected: ClickHouseConnection.InsertSchemaColumn
    ) throws(ClickHouseError) {
        if declared.name != expected.name {
            throw .protocolError(
                stage: "insert.schema",
                message: "column name mismatch: encoded '\(declared.name)', server expects '\(expected.name)'"
            )
        }
    }
}

// Records the first decode failure seen while a SELECT stream is still
// draining inbound blocks. The drain continues to EndOfStream so the
// connection is left at a clean packet boundary; the recorded error is
// surfaced to the consumer only once draining finishes.
enum StreamDecodeOutcome {

    case ok
    case failed(ClickHouseError)

    func finish<T>(_ continuation: AsyncThrowingStream<T, Error>.Continuation) {
        switch self {
        case .ok:
            continuation.finish()
        case .failed(let error):
            continuation.finish(throwing: error)
        }
    }
}

// Internal Codable wrapper for the scalar(_:as:) path. Decodes a row
// containing exactly one column under a fixed key, then unwraps the
// stored value. Lets the columnar Codable decoder do all the work
// without inventing a separate code path for "single-column SELECT".
struct ScalarRowWrapper<Value: Decodable & Sendable>: Decodable, Sendable {

    static var scalarKey: String { "__dx_raw_scalar__" }

    let value: Value

    enum CodingKeys: String, CodingKey {
        case value = "__dx_raw_scalar__"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(Value.self, forKey: .value)
    }
}

// Boxes the sync transport behind a final-class so the worker queue
// can capture and mutate it without crossing actor isolation on
// every wire-byte touch. The actor owns the box exclusively; concurrent
// access is gated by the actor's serial executor and the worker's
// FIFO queue ordering.
final class ClientTransportBox: @unchecked Sendable {

    let connection: ClickHouseConnection

    // True while a backpressured result stream holds the single connection mid
    // result, between its per-block worker hops. A second query that started in
    // that window would interleave its bytes on the shared connection and
    // cross-talk; the collecting query paths and a second stream check this and
    // fail with a clear error instead. Mutated only on the serial worker (and
    // the stream's deinit hop onto that worker), so it needs no atomic.
    var queryActive = false

    init(connection: ClickHouseConnection) {
        self.connection = connection
    }
}
