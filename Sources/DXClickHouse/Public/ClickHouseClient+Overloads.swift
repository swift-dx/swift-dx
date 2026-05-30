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

// Public input-form overloads for ClickHouseClient. Every operation
// that takes a payload (SQL bytes, Codable row collections, Codable
// scalar replies) is offered in every form the architecture rule
// requires: raw `[UInt8]`, Foundation `Encodable`/`Decodable` via JSON,
// `Sequence`, `AsyncSequence`, callback (`DXCallback`), and continuous
// `DXMessageHandler`.
//
// The performance primitive is the raw `[UInt8]` form (SQL bytes for
// reads, native-encoded Data packet bytes for writes). Every other
// overload converts to the primitive and delegates. No NIO `ByteBuffer`
// overload is offered: the raw transport intentionally does not depend
// on NIOCore, and adding the dependency for one convenience type would
// defeat the entire reason this client exists.

extension ClickHouseClient {

    public func execute(_ sql: String) async throws(ClickHouseError) {
        try await executeAndDrain(sql: sql)
    }

    public func execute(_ sqlBytes: [UInt8]) async throws(ClickHouseError) {
        try await executeAndDrain(sql: Self.decodeSQL(sqlBytes))
    }

    public nonisolated func execute(_ sql: String, completion: @escaping DXCallback<Void, ClickHouseError>) {
        Task { [self] in
            do {
                try await self.execute(sql)
                completion(.success(()))
            } catch let error as ClickHouseError {
                completion(.failure(error))
            } catch {
                completion(.failure(.protocolError(stage: "execute.callback", message: "\(error)")))
            }
        }
    }

    public nonisolated func ping(completion: @escaping DXCallback<Void, ClickHouseError>) {
        Task { [self] in
            do {
                try await self.ping()
                completion(.success(()))
            } catch let error as ClickHouseError {
                completion(.failure(error))
            } catch {
                completion(.failure(.protocolError(stage: "ping.callback", message: "\(error)")))
            }
        }
    }

    public func ping() async throws(ClickHouseError) {
        try await pingDrain()
    }

    public func scalar<T: Decodable & Sendable>(
        _ sqlBytes: [UInt8],
        as type: T.Type
    ) async throws(ClickHouseError) -> T {
        try await scalar(Self.decodeSQL(sqlBytes), as: type)
    }

    public nonisolated func scalar<T: Decodable & Sendable>(
        _ sql: String,
        as type: T.Type,
        completion: @escaping DXCallback<T, ClickHouseError>
    ) {
        Task { [self] in
            do {
                let value = try await self.scalar(sql, as: type)
                completion(.success(value))
            } catch let error as ClickHouseError {
                completion(.failure(error))
            } catch {
                completion(.failure(.protocolError(stage: "scalar.callback", message: "\(error)")))
            }
        }
    }

    public nonisolated func select<T: Decodable & Sendable>(
        _ sqlBytes: [UInt8],
        as type: T.Type,
        settings: ClickHouseQuerySettings = .empty,
        parameters: ClickHouseQueryParameters = .empty
    ) -> AsyncThrowingStream<T, Error> {
        select(Self.decodeSQL(sqlBytes), as: type, settings: settings, parameters: parameters)
    }

    public func selectAll<T: Decodable & Sendable>(
        _ sql: String,
        as type: T.Type,
        settings: ClickHouseQuerySettings = .empty,
        parameters: ClickHouseQueryParameters = .empty
    ) async throws(ClickHouseError) -> [T] {
        try await Self.collectRows(stream: select(sql, as: type, settings: settings, parameters: parameters))
    }

    public func selectAll<T: Decodable & Sendable>(
        _ sqlBytes: [UInt8],
        as type: T.Type,
        settings: ClickHouseQuerySettings = .empty,
        parameters: ClickHouseQueryParameters = .empty
    ) async throws(ClickHouseError) -> [T] {
        try await selectAll(Self.decodeSQL(sqlBytes), as: type, settings: settings, parameters: parameters)
    }

    public nonisolated func select<T: Decodable & Sendable>(
        _ sql: String,
        as type: T.Type,
        completion: @escaping DXCallback<[T], ClickHouseError>
    ) {
        Task { [self] in
            do {
                let rows = try await self.selectAll(sql, as: type)
                completion(.success(rows))
            } catch let error as ClickHouseError {
                completion(.failure(error))
            } catch {
                completion(.failure(.protocolError(stage: "select.callback", message: "\(error)")))
            }
        }
    }

    public nonisolated func stream<T: Decodable & Sendable, Handler: DXMessageHandler<T, ClickHouseError>>(
        _ sql: String,
        as type: T.Type,
        handler: Handler
    ) -> Task<Void, Never> {
        let upstream = select(sql, as: type)
        return Task { await Self.pumpStream(upstream: upstream, handler: handler) }
    }

    public nonisolated func stream<T: Decodable & Sendable, Handler: DXMessageHandler<T, ClickHouseError>>(
        _ sqlBytes: [UInt8],
        as type: T.Type,
        handler: Handler
    ) -> Task<Void, Never> {
        stream(Self.decodeSQL(sqlBytes), as: type, handler: handler)
    }

    public func insert<S: Sequence & Sendable>(
        into table: String,
        rows: S
    ) async throws(ClickHouseError) -> ClickHouseInsertSummary where S.Element: Encodable & Sendable {
        try await insert(into: table, rows: Array(rows))
    }

    public func insert<Source: AsyncSequence & Sendable, Row: Encodable & Sendable>(
        into table: String,
        rows: Source
    ) async throws(ClickHouseError) -> ClickHouseInsertSummary where Source.Element == Row {
        let collected = try await Self.materialise(rows: rows)
        return try await insert(into: table, rows: collected)
    }

    public func insertNativeBlock(
        into table: String,
        columnList: String,
        nativeBlockBytes: [UInt8]
    ) async throws(ClickHouseError) -> ClickHouseInsertSummary {
        try await sendPreEncodedInsert(
            table: table,
            columnList: columnList,
            nativeBlockBytes: nativeBlockBytes
        )
    }

    public nonisolated func insert<T: Encodable & Sendable>(
        into table: String,
        rows: [T],
        completion: @escaping DXCallback<ClickHouseInsertSummary, ClickHouseError>
    ) {
        Task { [self] in
            do {
                let summary = try await self.insert(into: table, rows: rows)
                completion(.success(summary))
            } catch let error as ClickHouseError {
                completion(.failure(error))
            } catch {
                completion(.failure(.protocolError(stage: "insert.callback", message: "\(error)")))
            }
        }
    }

    private func executeAndDrain(sql: String) async throws(ClickHouseError) {
        try await runOnTransport { transport throws(ClickHouseError) in
            try transport.connection.sendQuery(sql)
            _ = try transport.connection.receiveBlocks { _, _ in }
        }
    }

    private func pingDrain() async throws(ClickHouseError) {
        try await runOnTransport { transport throws(ClickHouseError) in
            try transport.connection.ping()
        }
    }

    private func sendPreEncodedInsert(
        table: String,
        columnList: String,
        nativeBlockBytes: [UInt8]
    ) async throws(ClickHouseError) -> ClickHouseInsertSummary {
        let terminator = ClickHouseBlockWriter.encodeEmptyDataPacket()
        let writtenCounters = try await runOnTransportReturning { transport throws(ClickHouseError) -> (UInt64, UInt64) in
            try transport.connection.sendQuery("INSERT INTO \(table) \(columnList) FORMAT Native")
            _ = try transport.connection.receiveInsertSampleSchema()
            try transport.connection.sendRawBytes(nativeBlockBytes)
            try transport.connection.sendRawBytes(terminator)
            return try transport.connection.receiveEndOfStream()
        }
        return ClickHouseInsertSummary(
            rowsSent: 0,
            blocksSent: 1,
            writtenRows: writtenCounters.0,
            writtenBytes: writtenCounters.1
        )
    }

    private static func decodeSQL(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: Unicode.UTF8.self)
    }

    private static func collectRows<T: Sendable>(
        stream: AsyncThrowingStream<T, Error>
    ) async throws(ClickHouseError) -> [T] {
        let outcome: Result<[T], ClickHouseError> = await drainStream(stream: stream)
        switch outcome {
        case .success(let rows): return rows
        case .failure(let error): throw error
        }
    }

    private static func drainStream<T: Sendable>(
        stream: AsyncThrowingStream<T, Error>
    ) async -> Result<[T], ClickHouseError> {
        do {
            return .success(try await collectAll(stream: stream))
        } catch {
            return .failure(toTypedError(error: error, stage: "collectRows"))
        }
    }

    private static func collectAll<T: Sendable>(
        stream: AsyncThrowingStream<T, Error>
    ) async throws -> [T] {
        var rows: [T] = []
        for try await row in stream { rows.append(row) }
        return rows
    }

    private static func toTypedError(error: Error, stage: String) -> ClickHouseError {
        switch error {
        case let typed as ClickHouseError: return typed
        default: return .protocolError(stage: stage, message: "\(error)")
        }
    }

    private static func materialise<Source: AsyncSequence & Sendable, Row: Encodable & Sendable>(
        rows: Source
    ) async throws(ClickHouseError) -> [Row] where Source.Element == Row {
        var collected: [Row] = []
        do {
            for try await row in rows { collected.append(row) }
        } catch {
            throw .protocolError(stage: "insert.asyncSequence", message: "\(error)")
        }
        return collected
    }

    private static func pumpStream<T: Decodable & Sendable, Handler: DXMessageHandler<T, ClickHouseError>>(
        upstream: AsyncThrowingStream<T, Error>,
        handler: Handler
    ) async {
        do {
            try await forwardRows(upstream: upstream, handler: handler)
        } catch {
            await handler.receive(error: toTypedError(error: error, stage: "stream"))
        }
    }

    private static func forwardRows<T: Decodable & Sendable, Handler: DXMessageHandler<T, ClickHouseError>>(
        upstream: AsyncThrowingStream<T, Error>,
        handler: Handler
    ) async throws {
        for try await row in upstream { await handler.receive(row) }
    }

    private func runOnTransport(
        _ body: @escaping @Sendable (ClientTransportBox) throws(ClickHouseError) -> Void
    ) async throws(ClickHouseError) {
        _ = try await runOnTransportReturning { transport throws(ClickHouseError) -> Int in
            try body(transport)
            return 0
        }
    }

    nonisolated func runOnTransportReturning<Value: Sendable>(
        _ body: @escaping @Sendable (ClientTransportBox) throws(ClickHouseError) -> Value
    ) async throws(ClickHouseError) -> Value {
        let outcome: Result<Value, ClickHouseError> = await dispatchOnWorker(body: body)
        switch outcome {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    private nonisolated func dispatchOnWorker<Value: Sendable>(
        body: @escaping @Sendable (ClientTransportBox) throws(ClickHouseError) -> Value
    ) async -> Result<Value, ClickHouseError> {
        let worker = self.workerForOverloads
        let transport = self.transportForOverloads
        return await withCheckedContinuation { continuation in
            worker.async {
                let captured = Self.runBody(body: body, transport: transport)
                continuation.resume(returning: captured)
            }
        }
    }

    private static func runBody<Value: Sendable>(
        body: @Sendable (ClientTransportBox) throws(ClickHouseError) -> Value,
        transport: ClientTransportBox
    ) -> Result<Value, ClickHouseError> {
        do {
            return .success(try body(transport))
        } catch {
            return .failure(error)
        }
    }
}
