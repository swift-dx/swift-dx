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

    public func close() async {
        let transport = self.transport
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            worker.async {
                transport.connection.close()
                continuation.resume()
            }
        }
    }

    // Returns an AsyncThrowingStream that yields one decoded `T` per
    // result row. The stream's declared failure type is `any Error`
    // because the standard library's `AsyncThrowingStream` does not yet
    // support a custom typed-failure parameter; every error this stream
    // surfaces is in fact a `ClickHouseError` and downstream callers
    // can downcast with `as` against the typed enum.
    public nonisolated func select<T: Decodable & Sendable>(
        _ sql: String,
        as type: T.Type,
        settings: ClickHouseQuerySettings = .empty,
        parameters: ClickHouseQueryParameters = .empty
    ) -> AsyncThrowingStream<T, Error> {
        let worker = self.worker
        let transport = self.transport
        return AsyncThrowingStream { continuation in
            worker.async {
                do {
                    try transport.connection.sendQuery(
                        sql,
                        queryID: "",
                        settings: settings,
                        parameters: parameters
                    )
                    _ = try transport.connection.receiveBlocks { block, body in
                        if block.rowCount == 0 { return }
                        let typed = try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: body)
                        let rows = try ClickHouseCodableDecoder.decodeRows(type: T.self, columns: typed, rowCount: block.rowCount)
                        for row in rows { continuation.yield(row) }
                    }
                    continuation.finish()
                } catch let error as ClickHouseError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: ClickHouseError.protocolError(stage: "select", message: "\(error)"))
                }
            }
        }
    }

    public func insert<T: Encodable & Sendable>(
        into table: String,
        rows: [T]
    ) async throws(ClickHouseError) -> ClickHouseInsertSummary {
        if rows.isEmpty {
            return ClickHouseInsertSummary(rowsSent: 0, blocksSent: 0, writtenRows: 0, writtenBytes: 0)
        }
        let encoder = ClickHouseRowEncoder()
        let columns = try encoder.encode(rows)
        let columnList = Self.makeColumnList(columns: columns)
        let sampleQuery = "INSERT INTO \(table) \(columnList) FORMAT Native"
        let revision = currentRevision()
        let dataPacket = try ClickHouseBlockWriter.encodeDataPacket(columns: columns, revision: revision)
        let terminator = ClickHouseBlockWriter.encodeEmptyDataPacket()
        let writtenCounters = try await runOnWorker { (transport: ClientTransportBox) throws(ClickHouseError) -> (UInt64, UInt64) in
            try transport.connection.sendQuery(sampleQuery)
            let schema = try transport.connection.receiveInsertSampleSchema()
            try Self.validateInsertSchema(declared: columns, sampleSchema: schema)
            try transport.connection.sendRawBytes(dataPacket)
            try transport.connection.sendRawBytes(terminator)
            return try transport.connection.receiveEndOfStream()
        }
        return ClickHouseInsertSummary(
            rowsSent: rows.count,
            blocksSent: 1,
            writtenRows: writtenCounters.0,
            writtenBytes: writtenCounters.1
        )
    }

    public func scalar<T: Decodable & Sendable>(
        _ sql: String,
        as type: T.Type
    ) async throws(ClickHouseError) -> T {
        let collected: Result<[T], ClickHouseError> = await collectScalar(sql: sql, type: T.self)
        let rows = try collected.get()
        guard rows.count == 1 else {
            throw .protocolError(stage: "scalar", message: "expected exactly one row + one column, got \(rows.count) rows")
        }
        return rows[0]
    }

    private nonisolated func collectScalar<T: Decodable & Sendable>(
        sql: String,
        type: T.Type
    ) async -> Result<[T], ClickHouseError> {
        var collected: [T] = []
        do {
            for try await element in selectScalarStream(sql: sql, type: T.self) {
                collected.append(element)
            }
        } catch let error as ClickHouseError {
            return .failure(error)
        } catch {
            return .failure(.protocolError(stage: "scalar", message: "\(error)"))
        }
        return .success(collected)
    }

    // Wraps SELECT in a way that synthesizes a single-key row decoder
    // for the value column. The query is expected to project exactly
    // one column, named anything; the wrapper decodes whichever column
    // appears in the first slot.
    private nonisolated func selectScalarStream<T: Decodable & Sendable>(
        sql: String,
        type: T.Type
    ) -> AsyncThrowingStream<T, Error> {
        let worker = self.worker
        let transport = self.transport
        return AsyncThrowingStream { continuation in
            worker.async {
                do {
                    try transport.connection.sendQuery(sql)
                    _ = try transport.connection.receiveBlocks { block, body in
                        if block.rowCount == 0 { return }
                        guard block.columnCount == 1 else {
                            throw ClickHouseError.protocolError(stage: "scalar", message: "expected one column, got \(block.columnCount)")
                        }
                        let typed = try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: body)
                        let renamed = [ClickHouseNamedColumn(name: ScalarRowWrapper<T>.scalarKey, column: typed[0].column)]
                        let rows = try ClickHouseCodableDecoder.decodeRows(
                            type: ScalarRowWrapper<T>.self,
                            columns: renamed,
                            rowCount: block.rowCount
                        )
                        for row in rows { continuation.yield(row.value) }
                    }
                    continuation.finish()
                } catch let error as ClickHouseError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: ClickHouseError.protocolError(stage: "scalar", message: "\(error)"))
                }
            }
        }
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

    private static func makeColumnList(columns: [ClickHouseNamedColumn]) -> String {
        let quoted = columns.map { "`\($0.name)`" }.joined(separator: ", ")
        return "(\(quoted))"
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
            if lhs.name != rhs.name {
                throw .protocolError(
                    stage: "insert.schema",
                    message: "column name mismatch: encoded '\(lhs.name)', server expects '\(rhs.name)'"
                )
            }
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

    init(connection: ClickHouseConnection) {
        self.connection = connection
    }
}
