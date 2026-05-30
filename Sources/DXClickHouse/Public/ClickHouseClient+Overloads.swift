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

    public func insert<S: Sequence & Sendable>(
        into table: String,
        rows: S,
        timeout: Duration = ClickHouseQueryDefaults.insertTimeout
    ) async throws(ClickHouseError) -> ClickHouseInsertSummary where S.Element: Encodable & Sendable {
        try await insert(into: table, rows: Array(rows), timeout: timeout)
    }

    public func insert<Source: AsyncSequence & Sendable, Row: Encodable & Sendable>(
        into table: String,
        rows: Source,
        timeout: Duration = ClickHouseQueryDefaults.insertTimeout
    ) async throws(ClickHouseError) -> ClickHouseInsertSummary where Source.Element == Row {
        let collected: [Row] = try await Self.materialise(rows: rows)
        return try await insert(into: table, rows: collected, timeout: timeout)
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

    static func decodeSQL(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: Unicode.UTF8.self)
    }

    static func materialise<Source: AsyncSequence & Sendable, Row: Encodable & Sendable>(
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
