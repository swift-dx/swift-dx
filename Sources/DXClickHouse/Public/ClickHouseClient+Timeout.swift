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
        timeout: Duration = ClickHouseQueryDefaults.selectTimeout,
        settings: ClickHouseQuerySettings = .empty,
        parameters: ClickHouseQueryParameters = .empty
    ) async throws(ClickHouseError) {
        let injected = Self.injectMaxExecutionTime(into: settings, timeout: timeout)
        let captured = self
        _ = try await Self.withTimeout(self, timeout: timeout) { () -> Int in
            try await captured.executeInternal(sql: sql, settings: injected, parameters: parameters)
            return 0
        }
    }

    public func execute(
        _ sqlBytes: [UInt8],
        timeout: Duration = ClickHouseQueryDefaults.selectTimeout,
        settings: ClickHouseQuerySettings = .empty,
        parameters: ClickHouseQueryParameters = .empty
    ) async throws(ClickHouseError) {
        try await execute(Self.decodeSQLBytes(sqlBytes), timeout: timeout, settings: settings, parameters: parameters)
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
        timeout: Duration = ClickHouseQueryDefaults.selectTimeout,
        settings: ClickHouseQuerySettings = .empty,
        parameters: ClickHouseQueryParameters = .empty
    ) async throws(ClickHouseError) -> T {
        let injected = Self.injectMaxExecutionTime(into: settings, timeout: timeout)
        return try await Self.withTimeout(self, timeout: timeout) {
            try await self.scalarInternal(sql: sql, type: type, settings: injected, parameters: parameters)
        }
    }

    public func scalar<T: Decodable & Sendable>(
        _ sqlBytes: [UInt8],
        as type: T.Type,
        timeout: Duration = ClickHouseQueryDefaults.selectTimeout,
        settings: ClickHouseQuerySettings = .empty,
        parameters: ClickHouseQueryParameters = .empty
    ) async throws(ClickHouseError) -> T {
        try await scalar(Self.decodeSQLBytes(sqlBytes), as: type, timeout: timeout, settings: settings, parameters: parameters)
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

    // Runs any query and returns its columns directly — no Codable type, no
    // conformance. The thin, protocol-close read: issue SQL, read columns by
    // name and row. selectAll / selectAllFused are typed conveniences on top.
    public func query(
        _ sql: String,
        timeout: Duration = ClickHouseQueryDefaults.selectTimeout,
        settings: ClickHouseQuerySettings = .empty,
        parameters: ClickHouseQueryParameters = .empty
    ) async throws(ClickHouseError) -> ClickHouseQueryResult {
        let injected = Self.injectMaxExecutionTime(into: settings, timeout: timeout)
        return try await Self.withTimeout(self, timeout: timeout) {
            try await self.collectQuery(sql: sql, settings: injected, parameters: parameters)
        }
    }

    // Fused fast-path read: single-pass decode straight from the received
    // bytes, no intermediate typed-column arrays. Lowest-overhead read.
    public func selectAllFused<T: ClickHouseFusedDecodable & Sendable>(
        _ sql: String,
        as type: T.Type,
        timeout: Duration = ClickHouseQueryDefaults.selectTimeout,
        settings: ClickHouseQuerySettings = .empty,
        parameters: ClickHouseQueryParameters = .empty
    ) async throws(ClickHouseError) -> [T] {
        let injected = Self.injectMaxExecutionTime(into: settings, timeout: timeout)
        return try await Self.withTimeout(self, timeout: timeout) {
            try await self.collectFused(sql: sql, settings: injected, parameters: parameters)
        }
    }

    // Columnar fast-path equivalent of `selectAll` for a ClickHouseRowDecodable
    // destination: same materialised array, decoded without Codable's per-row
    // container allocation.
    public func selectAllFast<T: ClickHouseRowDecodable & Sendable>(
        _ sql: String,
        as type: T.Type,
        timeout: Duration = ClickHouseQueryDefaults.selectTimeout,
        settings: ClickHouseQuerySettings = .empty,
        parameters: ClickHouseQueryParameters = .empty
    ) async throws(ClickHouseError) -> [T] {
        let injected = Self.injectMaxExecutionTime(into: settings, timeout: timeout)
        return try await Self.withTimeout(self, timeout: timeout) {
            try await self.selectAllFastInternal(
                sql: sql,
                type: type,
                settings: injected,
                parameters: parameters
            )
        }
    }

    nonisolated func selectAllFastInternal<T: ClickHouseRowDecodable & Sendable>(
        sql: String,
        type: T.Type,
        settings: ClickHouseQuerySettings,
        parameters: ClickHouseQueryParameters
    ) async throws(ClickHouseError) -> [T] {
        try await collectFast(sql: sql, settings: settings, parameters: parameters)
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
        let injected = Self.injectMaxExecutionTime(into: settings, timeout: timeout)
        return try await Self.withTimeout(self, timeout: timeout) {
            try await self.insertInternal(into: table, rows: rows, settings: injected)
        }
    }

    // Columnar fast-path equivalent of `insert` for a ClickHouseColumnarEncodable
    // batch: the same INSERT, encoded column-by-column without Codable's per-row
    // container allocation.
    public func insertFast<T: ClickHouseColumnarEncodable & Sendable>(
        into table: String,
        rows: [T],
        timeout: Duration = ClickHouseQueryDefaults.insertTimeout,
        settings: ClickHouseQuerySettings = .empty
    ) async throws(ClickHouseError) -> ClickHouseInsertSummary {
        let injected = Self.injectMaxExecutionTime(into: settings, timeout: timeout)
        return try await Self.withTimeout(self, timeout: timeout) {
            try await self.insertFastCore(into: table, rows: rows, settings: injected)
        }
    }

    public func insertNativeBlock(
        into table: String,
        columnList: String,
        nativeBlockBytes: [UInt8],
        timeout: Duration = ClickHouseQueryDefaults.insertTimeout,
        settings: ClickHouseQuerySettings = .empty
    ) async throws(ClickHouseError) -> ClickHouseInsertSummary {
        let injected = Self.injectMaxExecutionTime(into: settings, timeout: timeout)
        return try await Self.withTimeout(self, timeout: timeout) {
            try await self.insertNativeBlockInternal(
                table: table,
                columnList: columnList,
                nativeBlockBytes: nativeBlockBytes,
                settings: injected
            )
        }
    }

    public nonisolated func stream<T: Decodable & Sendable, Handler: DXMessageHandler<T, ClickHouseError>>(
        _ sql: String,
        as type: T.Type,
        timeout: Duration = ClickHouseQueryDefaults.streamTimeout,
        settings: ClickHouseQuerySettings = .empty,
        handler: Handler
    ) -> Task<Void, Never> {
        let captured = self
        return Task {
            do {
                _ = try await Self.withTimeout(captured, timeout: timeout) { () -> Int in
                    let upstream = captured.select(sql, as: type, settings: settings)
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
        settings: ClickHouseQuerySettings = .empty,
        handler: Handler
    ) -> Task<Void, Never> {
        stream(Self.decodeSQLBytes(sqlBytes), as: type, timeout: timeout, settings: settings, handler: handler)
    }

    // Internal helpers below. These mirror the bodies of the
    // timeout-free public methods so the timeout-bearing overloads can
    // run them inside the race without re-entering an actor hop that
    // would compete with the timeout's onTimeout callback.

    nonisolated func executeInternal(
        sql: String,
        settings: ClickHouseQuerySettings,
        parameters: ClickHouseQueryParameters
    ) async throws(ClickHouseError) {
        _ = try await runOnTransportReturning { (transport: ClientTransportBox) throws(ClickHouseError) -> Int in
            try transport.connection.sendQuery(
                sql,
                queryID: "",
                settings: settings,
                parameters: parameters
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
        settings: ClickHouseQuerySettings,
        parameters: ClickHouseQueryParameters
    ) async throws(ClickHouseError) -> T {
        let stream = selectScalarStream(sql: sql, type: type, settings: settings, parameters: parameters)
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
        try await collectCodable(sql: sql, settings: settings, parameters: parameters)
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

    // Fixed POSIX locale used to format the max_execution_time wire value.
    // On Linux, String(format:) without an explicit locale honors
    // LC_NUMERIC, so a process that called setlocale to a comma-decimal
    // locale (de_DE, fr_FR, and most of continental Europe) would emit
    // e.g. "1,500" and send ClickHouse a malformed setting that breaks the
    // server-side query timeout. Formatting against en_US_POSIX pins the
    // decimal separator to '.' regardless of the host locale.
    private static let wireNumberLocale = Locale(identifier: "en_US_POSIX")

    private static func formatSeconds(_ seconds: Double) -> String {
        if seconds >= 1 {
            return String(format: "%.3f", locale: wireNumberLocale, seconds)
        }
        // A positive sub-microsecond timeout would format to "0.000000" at
        // six decimals, which ClickHouse reads as max_execution_time=0 = no
        // limit — the opposite of a deadline. Clamp up to the smallest value
        // the format can represent so the server-side bound stays positive.
        let bounded = Swift.max(seconds, 0.000001)
        return String(format: "%.6f", locale: wireNumberLocale, bounded)
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
