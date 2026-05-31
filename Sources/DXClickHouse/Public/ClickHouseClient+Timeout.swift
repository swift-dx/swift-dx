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

// Per-query timeout overloads on ClickHouseClient. Every public
// operation gets a sibling method that takes a `timeout: Duration`
// parameter and races the underlying async work against that deadline.
//
// Behaviour:
//   * If the operation completes before the deadline, the value is
//     returned to the caller exactly as the timeout-free overload
//     would have returned it.
//   * If the deadline fires first, the helper throws
//     `ClickHouseError.queryTimeout(elapsed:)` and calls
//     `shutdownSocketForTimeout()` on the live connection so the
//     in-flight blocking recv()/send() returns immediately, the worker
//     queue unblocks, and the connection's reconnect path establishes
//     a fresh socket for the next operation.
//   * The server-side `max_execution_time` setting is injected into the
//     query for SELECT-shaped operations so the server itself stops
//     processing even if the local cancel race loses. This bounds
//     server-side resource use regardless of network conditions.
//
// `timeout: .zero` disables the local timeout for one call; the
// server-side `max_execution_time` is also skipped in that case so the
// caller has a deliberate "no deadline" escape hatch.

extension ClickHouseClient {

    public func execute(
        _ sql: String,
        timeout: Duration = ClickHouseQueryDefaults.selectTimeout
    ) async throws(ClickHouseError) {
        let injected = Self.injectMaxExecutionTime(into: .empty, timeout: timeout)
        let captured = self
        _ = try await Self.withTimeout(self, timeout: timeout) { () -> Int in
            try await captured.executeInternal(sql: sql, settings: injected)
            return 0
        }
    }

    public func execute(
        _ sqlBytes: [UInt8],
        timeout: Duration = ClickHouseQueryDefaults.selectTimeout
    ) async throws(ClickHouseError) {
        try await execute(Self.decodeSQLBytes(sqlBytes), timeout: timeout)
    }

    public func ping(
        timeout: Duration = ClickHouseQueryDefaults.pingTimeout
    ) async throws(ClickHouseError) {
        try await Self.withTimeout(self, timeout: timeout) {
            try await self.pingInternal()
        }
    }

    public func scalar<T: Decodable & Sendable>(
        _ sql: String,
        as type: T.Type,
        timeout: Duration = ClickHouseQueryDefaults.selectTimeout
    ) async throws(ClickHouseError) -> T {
        let injected = Self.injectMaxExecutionTime(into: .empty, timeout: timeout)
        return try await Self.withTimeout(self, timeout: timeout) {
            try await self.scalarInternal(sql: sql, type: type, settings: injected)
        }
    }

    public func scalar<T: Decodable & Sendable>(
        _ sqlBytes: [UInt8],
        as type: T.Type,
        timeout: Duration = ClickHouseQueryDefaults.selectTimeout
    ) async throws(ClickHouseError) -> T {
        try await scalar(Self.decodeSQLBytes(sqlBytes), as: type, timeout: timeout)
    }

    public func selectAll<T: Decodable & Sendable>(
        _ sql: String,
        as type: T.Type,
        timeout: Duration = ClickHouseQueryDefaults.selectTimeout,
        settings: ClickHouseQuerySettings = .empty,
        parameters: ClickHouseQueryParameters = .empty
    ) async throws(ClickHouseError) -> [T] {
        let injected = Self.injectMaxExecutionTime(into: settings, timeout: timeout)
        return try await Self.withTimeout(self, timeout: timeout) {
            try await self.selectAllInternal(
                sql: sql,
                type: type,
                settings: injected,
                parameters: parameters
            )
        }
    }

    public func selectAll<T: Decodable & Sendable>(
        _ sqlBytes: [UInt8],
        as type: T.Type,
        timeout: Duration = ClickHouseQueryDefaults.selectTimeout,
        settings: ClickHouseQuerySettings = .empty,
        parameters: ClickHouseQueryParameters = .empty
    ) async throws(ClickHouseError) -> [T] {
        try await selectAll(
            Self.decodeSQLBytes(sqlBytes),
            as: type,
            timeout: timeout,
            settings: settings,
            parameters: parameters
        )
    }

    public func insert<T: Encodable & Sendable>(
        into table: String,
        rows: [T],
        timeout: Duration = ClickHouseQueryDefaults.insertTimeout,
        settings: ClickHouseQuerySettings = .empty
    ) async throws(ClickHouseError) -> ClickHouseInsertSummary {
        try await Self.withTimeout(self, timeout: timeout) {
            try await self.insertInternal(into: table, rows: rows, settings: settings)
        }
    }

    public func insertNativeBlock(
        into table: String,
        columnList: String,
        nativeBlockBytes: [UInt8],
        timeout: Duration = ClickHouseQueryDefaults.insertTimeout,
        settings: ClickHouseQuerySettings = .empty
    ) async throws(ClickHouseError) -> ClickHouseInsertSummary {
        try await Self.withTimeout(self, timeout: timeout) {
            try await self.insertNativeBlockInternal(
                table: table,
                columnList: columnList,
                nativeBlockBytes: nativeBlockBytes,
                settings: settings
            )
        }
    }

    public nonisolated func stream<T: Decodable & Sendable, Handler: DXMessageHandler<T, ClickHouseError>>(
        _ sql: String,
        as type: T.Type,
        timeout: Duration = ClickHouseQueryDefaults.streamTimeout,
        handler: Handler
    ) -> Task<Void, Never> {
        let captured = self
        return Task {
            do {
                _ = try await Self.withTimeout(captured, timeout: timeout) { () -> Int in
                    let upstream = captured.select(sql, as: type)
                    try await Self.forwardRowsToHandler(upstream: upstream, handler: handler)
                    return 0
                }
            } catch let error as ClickHouseError {
                await handler.receive(error: error)
            } catch {
                await handler.receive(error: .protocolError(stage: "stream.timeout", message: "\(error)"))
            }
        }
    }

    public nonisolated func stream<T: Decodable & Sendable, Handler: DXMessageHandler<T, ClickHouseError>>(
        _ sqlBytes: [UInt8],
        as type: T.Type,
        timeout: Duration = ClickHouseQueryDefaults.streamTimeout,
        handler: Handler
    ) -> Task<Void, Never> {
        stream(Self.decodeSQLBytes(sqlBytes), as: type, timeout: timeout, handler: handler)
    }

    // Internal helpers below. These mirror the bodies of the
    // timeout-free public methods so the timeout-bearing overloads can
    // run them inside the race without re-entering an actor hop that
    // would compete with the timeout's onTimeout callback.

    nonisolated func executeInternal(
        sql: String,
        settings: ClickHouseQuerySettings
    ) async throws(ClickHouseError) {
        _ = try await runOnTransportReturning { (transport: ClientTransportBox) throws(ClickHouseError) -> Int in
            try transport.connection.sendQuery(
                sql,
                queryID: "",
                settings: settings,
                parameters: .empty
            )
            _ = try transport.connection.receiveBlocks { _, _ in }
            return 0
        }
    }

    nonisolated func pingInternal() async throws(ClickHouseError) {
        _ = try await runOnTransportReturning { (transport: ClientTransportBox) throws(ClickHouseError) -> Int in
            try transport.connection.ping()
            return 0
        }
    }

    nonisolated func scalarInternal<T: Decodable & Sendable>(
        sql: String,
        type: T.Type,
        settings: ClickHouseQuerySettings
    ) async throws(ClickHouseError) -> T {
        let stream = selectScalarStream(sql: sql, type: type, settings: settings)
        var collected: [T] = []
        do {
            for try await value in stream { collected.append(value) }
        } catch let error as ClickHouseError {
            throw error
        } catch {
            throw .protocolError(stage: "scalar", message: "\(error)")
        }
        guard collected.count == 1 else {
            throw .protocolError(stage: "scalar", message: "expected exactly one row + one column, got \(collected.count) rows")
        }
        return collected[0]
    }

    nonisolated func selectAllInternal<T: Decodable & Sendable>(
        sql: String,
        type: T.Type,
        settings: ClickHouseQuerySettings,
        parameters: ClickHouseQueryParameters
    ) async throws(ClickHouseError) -> [T] {
        let stream = select(sql, as: type, settings: settings, parameters: parameters)
        do {
            var collected: [T] = []
            for try await row in stream { collected.append(row) }
            return collected
        } catch let error as ClickHouseError {
            throw error
        } catch {
            throw .protocolError(stage: "selectAllInternal", message: "\(error)")
        }
    }

    nonisolated func insertInternal<T: Encodable & Sendable>(
        into table: String,
        rows: [T],
        settings: ClickHouseQuerySettings
    ) async throws(ClickHouseError) -> ClickHouseInsertSummary {
        try await self.insertCore(into: table, rows: rows, settings: settings)
    }

    nonisolated func insertNativeBlockInternal(
        table: String,
        columnList: String,
        nativeBlockBytes: [UInt8],
        settings: ClickHouseQuerySettings
    ) async throws(ClickHouseError) -> ClickHouseInsertSummary {
        try await self.insertNativeBlockCore(
            into: table,
            columnList: columnList,
            nativeBlockBytes: nativeBlockBytes,
            settings: settings
        )
    }

    @inline(__always)
    static func withTimeout<Value: Sendable>(
        _ client: ClickHouseClient,
        timeout: Duration,
        _ body: @escaping @Sendable () async throws -> Value
    ) async throws(ClickHouseError) -> Value {
        if timeout == .zero {
            do {
                return try await body()
            } catch let typed as ClickHouseError {
                throw typed
            } catch {
                throw ClickHouseError.protocolError(stage: "timeout.passthrough", message: "\(error)")
            }
        }
        let transport = client.transportForOverloads
        return try await ClickHouseTimeout.run(
            timeout: timeout,
            onTimeout: { transport.connection.shutdownSocketForTimeout() },
            body: body
        )
    }

    // Injects the server-side `max_execution_time` setting so the
    // ClickHouse server itself stops processing the query when the
    // deadline expires, even if the local cancel race loses or the
    // socket-shutdown never reaches the server. The setting is
    // expressed in fractional seconds; the server parses the string
    // representation.
    static func injectMaxExecutionTime(
        into settings: ClickHouseQuerySettings,
        timeout: Duration
    ) -> ClickHouseQuerySettings {
        if timeout == .zero { return settings }
        let seconds = durationToSeconds(timeout)
        if seconds <= 0 { return settings }
        for entry in settings.entries where entry.name == "max_execution_time" {
            return settings
        }
        var updated = settings.entries
        updated.append(
            ClickHouseQuerySetting(
                name: "max_execution_time",
                value: formatSeconds(seconds),
                important: false
            )
        )
        return ClickHouseQuerySettings(updated)
    }

    private static func durationToSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        if seconds >= 1 {
            return String(format: "%.3f", seconds)
        }
        return String(format: "%.6f", seconds)
    }

    static func decodeSQLBytes(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: Unicode.UTF8.self)
    }

    static func forwardRowsToHandler<T: Decodable & Sendable, Handler: DXMessageHandler<T, ClickHouseError>>(
        upstream: AsyncThrowingStream<T, Error>,
        handler: Handler
    ) async throws {
        for try await row in upstream {
            await handler.receive(row)
        }
    }
}
