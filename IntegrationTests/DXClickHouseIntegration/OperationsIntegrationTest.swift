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

import DXClickHouse
import Foundation
import Testing

// Integration cover for the production operation surface. Gated on
// CH_INTEGRATION_HOST so it only runs when a live ClickHouse is wired.
@Suite(
    "DXClickHouse integration: production operation surface",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseOperationsIntegration {

    private static var host: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
    }

    private static var port: Int {
        Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
    }

    private static var user: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default"
    }

    private static var password: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? ""
    }

    private static var database: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "default"
    }

    private static func connect() throws -> ClickHouseConnection {
        try ClickHouseConnection(
            host: host,
            port: port,
            user: user,
            password: password,
            database: database
        )
    }

    // ---- Settings ----

    @Test("Query with server setting max_threads=1 round-trips a scalar")
    func settingsRoundtrip() throws {
        let connection = try Self.connect()
        defer { connection.close() }
        let settings = ClickHouseQuerySettings([
            ClickHouseQuerySetting(name: "max_threads", value: "1"),
        ])
        try connection.sendQuery(
            "SELECT toUInt64(42)",
            queryID: "settings-roundtrip",
            settings: settings,
            parameters: .empty
        )
        let value = try connection.receiveScalarUInt64()
        #expect(value == 42)
    }

    @Test("Query with an unknown important setting is rejected by the server")
    func settingsUnknownRejected() throws {
        let connection = try Self.connect()
        defer { connection.close() }
        let settings = ClickHouseQuerySettings([
            ClickHouseQuerySetting(name: "this_setting_does_not_exist_anywhere", value: "1", important: true),
        ])
        var caught: ClickHouseError = .reconnectExhausted(attempts: 0)
        do {
            try connection.sendQuery("SELECT 1", queryID: "settings-unknown", settings: settings)
            _ = try connection.receiveBlocks { _, _ in }
        } catch let error {
            caught = error
        }
        switch caught {
        case .queryFailed(let exception):
            #expect(exception.code != 0)
        case .connectionFailed, .socketIOFailed, .unexpectedEOF, .protocolError, .reconnectExhausted, .endpointsExhausted:
            Issue.record("expected queryFailed, got \(caught)")
        }
    }

    // ---- Parameters ----

    @Test("Parameterised query substitutes a UInt64 binding")
    func parameterisedQuery() throws {
        let connection = try Self.connect()
        defer { connection.close() }
        // ClickHouse Field-literal form for non-String types requires
        // single-quoted values; the raw transport intentionally does NOT
        // add the quoting (it preserves the byte-for-byte value the
        // caller supplies), so the caller wraps the literal here.
        let parameters = ClickHouseQueryParameters([
            ClickHouseQueryParameter(name: "value", value: "'1729'"),
        ])
        try connection.sendQuery(
            "SELECT {value:UInt64}",
            queryID: "params-roundtrip",
            settings: .empty,
            parameters: parameters
        )
        let value = try connection.receiveScalarUInt64()
        #expect(value == 1729)
    }

    // ---- Server exception ----

    @Test("Malformed SQL surfaces a typed ClickHouseServerException")
    func serverExceptionTyped() throws {
        let connection = try Self.connect()
        defer { connection.close() }
        var caught: ClickHouseError = .reconnectExhausted(attempts: 0)
        do {
            try connection.sendQuery("SELECT * FROM table_that_does_not_exist_anywhere", queryID: "exception-test")
            _ = try connection.receiveBlocks { _, _ in }
        } catch let error {
            caught = error
        }
        switch caught {
        case .queryFailed(let exception):
            #expect(exception.code != 0)
            #expect(!exception.name.isEmpty)
            #expect(!exception.message.isEmpty)
        case .connectionFailed, .socketIOFailed, .unexpectedEOF, .protocolError, .reconnectExhausted, .endpointsExhausted:
            Issue.record("expected queryFailed with server exception, got \(caught)")
        }
    }

    // ---- Progress callback ----

    @Test("Progress callback fires for a numbers-table SELECT")
    func progressCallbackFires() throws {
        let connection = try Self.connect()
        defer { connection.close() }
        let settings = ClickHouseQuerySettings([
            // Force the server to emit Progress packets frequently.
            ClickHouseQuerySetting(name: "interactive_delay", value: "100000"),
        ])
        try connection.sendQuery(
            "SELECT count() FROM numbers(1000000)",
            queryID: "progress-test",
            settings: settings
        )
        var progressFired = 0
        let callbacks = ClickHouseConnection.ReceiveCallbacks(
            onProgress: { _ in progressFired += 1 }
        )
        let rows = try connection.receiveBlocks(callbacks: callbacks) { _, _ in }
        #expect(rows == 1)
        #expect(progressFired >= 1)
    }

    // ---- ProfileInfo callback ----

    @Test("ProfileInfo callback delivers a non-zero rows count")
    func profileInfoCallback() throws {
        let connection = try Self.connect()
        defer { connection.close() }
        try connection.sendQuery("SELECT number FROM numbers(100) LIMIT 50", queryID: "profile-info-test")
        var profileInfo = ClickHouseProfileInfo(
            rows: 0, blocks: 0, bytes: 0,
            appliedLimit: false, rowsBeforeLimit: 0, calculatedRowsBeforeLimit: false
        )
        let callbacks = ClickHouseConnection.ReceiveCallbacks(
            onProfileInfo: { profileInfo = $0 }
        )
        _ = try connection.receiveBlocks(callbacks: callbacks) { _, _ in }
        #expect(profileInfo.rows >= 50)
    }

    // ---- Query ID ----

    @Test("queryID surfaces in system.query_log")
    func queryIDInLog() throws {
        let connection = try Self.connect()
        defer { connection.close() }
        let queryID = "swift-dx-raw-test-\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        try connection.sendQuery("SELECT 1", queryID: queryID)
        _ = try connection.receiveBlocks { _, _ in }
        try connection.sendQuery("SYSTEM FLUSH LOGS", queryID: "")
        _ = try connection.receiveBlocks { _, _ in }
        let parameters = ClickHouseQueryParameters([
            ClickHouseQueryParameter(name: "qid", value: "'\(queryID)'"),
        ])
        try connection.sendQuery(
            "SELECT count() FROM system.query_log WHERE query_id = {qid:String}",
            queryID: "query-id-verify",
            parameters: parameters
        )
        let count = try connection.receiveScalarUInt64()
        #expect(count >= 1)
    }

    // ---- Ping ----

    @Test("Ping round-trips against a live broker")
    func pingRoundTrip() throws {
        let connection = try Self.connect()
        defer { connection.close() }
        try connection.ping()
        // After ping, the connection is still usable.
        try connection.sendQuery("SELECT toUInt64(99)", queryID: "post-ping")
        let value = try connection.receiveScalarUInt64()
        #expect(value == 99)
    }
}

// Integration cover for the async surface (settings, parameters, ping,
// progress callbacks).
@Suite(
    "DXClickHouse integration: async operation surface",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct AsyncRawClickHouseOperationsIntegration {

    private static var host: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
    }

    private static var port: Int {
        Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
    }

    private static var user: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default"
    }

    private static var password: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? ""
    }

    private static var database: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "default"
    }

    private static func connect() async throws -> AsyncClickHouseConnection {
        try await AsyncClickHouseConnection(
            host: host, port: port,
            user: user, password: password, database: database
        )
    }

    @Test("Async parameterised query round-trips a scalar")
    func asyncParameterisedQuery() async throws {
        let connection = try await Self.connect()
        try await connection.sendQuery(
            "SELECT {value:UInt64}",
            queryID: "async-params",
            settings: .empty,
            parameters: ClickHouseQueryParameters([
                ClickHouseQueryParameter(name: "value", value: "'12345'"),
            ])
        )
        let value = try await connection.receiveScalarUInt64()
        #expect(value == 12345)
        await connection.close()
    }

    @Test("Async ping round-trips against a live broker")
    func asyncPing() async throws {
        let connection = try await Self.connect()
        try await connection.ping()
        try await connection.sendQuery("SELECT toUInt64(7)", queryID: "async-post-ping")
        let value = try await connection.receiveScalarUInt64()
        #expect(value == 7)
        await connection.close()
    }

    @Test("Async drainBlocks(onProgress:) fires for a large scan")
    func asyncDrainBlocksWithProgress() async throws {
        let connection = try await Self.connect()
        try await connection.sendQuery(
            "SELECT count() FROM numbers(500000)",
            queryID: "async-progress",
            settings: ClickHouseQuerySettings([
                ClickHouseQuerySetting(name: "interactive_delay", value: "100000"),
            ])
        )
        nonisolated(unsafe) var progressFired = 0
        _ = try await connection.drainBlocks(
            onProgress: { _ in progressFired += 1 }
        )
        #expect(progressFired >= 1)
        await connection.close()
    }
}

// Integration cover for the pool's new TTL / preflight / failover
// features. Gated on CH_INTEGRATION_HOST.
@Suite(
    "DXClickHouse integration: pool features",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseConnectionPoolFeaturesIntegration {

    private static var host: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
    }

    private static var port: Int {
        Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
    }

    private static var user: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default"
    }

    private static var password: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? ""
    }

    private static var database: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "default"
    }

    @Test("Multi-endpoint pool with one unreachable + one live succeeds via failover")
    func multiEndpointFailover() async throws {
        let configuration = ClickHouseConnectionPool.Configuration(
            endpoints: [
                ClickHouseEndpoint(host: "127.0.0.1", port: 1),
                ClickHouseEndpoint(host: Self.host, port: Self.port),
            ],
            user: Self.user,
            password: Self.password,
            database: Self.database,
            minConnections: 1,
            maxConnections: 4,
            acquireTimeout: .seconds(5),
            evictionInterval: .seconds(60)
        )
        let pool = try await ClickHouseConnectionPool(configuration: configuration)
        let value = try await pool.withConnection { connection in
            try await connection.sendQuery("SELECT toUInt64(42)", queryID: "failover-test")
            return try await connection.receiveScalarUInt64()
        }
        #expect(value == 42)
        let stats = await pool.stats()
        #expect(stats.endpointFailovers >= 1)
        await pool.close()
    }

    @Test("idleConnectionTTL evicts connections idle longer than the TTL")
    func idleTTLEvicts() async throws {
        let configuration = ClickHouseConnectionPool.Configuration(
            host: Self.host,
            port: Self.port,
            user: Self.user,
            password: Self.password,
            database: Self.database,
            minConnections: 1,
            maxConnections: 2,
            acquireTimeout: .seconds(5),
            idleConnectionTTL: .milliseconds(100),
            maxConnectionLifetime: .seconds(3600),
            preflightPing: false,
            evictionInterval: .milliseconds(50)
        )
        let pool = try await ClickHouseConnectionPool(configuration: configuration)
        try await Task.sleep(for: .milliseconds(500))
        let stats = await pool.stats()
        #expect(stats.evictedByIdleTTL >= 1)
        await pool.close()
    }

    @Test("preflightPing handshake check passes on a healthy broker")
    func preflightPingPasses() async throws {
        let configuration = ClickHouseConnectionPool.Configuration(
            host: Self.host,
            port: Self.port,
            user: Self.user,
            password: Self.password,
            database: Self.database,
            minConnections: 1,
            maxConnections: 2,
            acquireTimeout: .seconds(5),
            preflightPing: true,
            evictionInterval: .seconds(60)
        )
        let pool = try await ClickHouseConnectionPool(configuration: configuration)
        for iteration in 0..<5 {
            let value = try await pool.withConnection { connection in
                try await connection.sendQuery("SELECT toUInt64(\(iteration))", queryID: "preflight-\(iteration)")
                return try await connection.receiveScalarUInt64()
            }
            #expect(value == UInt64(iteration))
        }
        await pool.close()
    }

    @Test("maxConnectionLifetime evicts an aged-out connection")
    func maxLifetimeEvicts() async throws {
        let configuration = ClickHouseConnectionPool.Configuration(
            host: Self.host,
            port: Self.port,
            user: Self.user,
            password: Self.password,
            database: Self.database,
            minConnections: 1,
            maxConnections: 2,
            acquireTimeout: .seconds(5),
            idleConnectionTTL: .seconds(3600),
            maxConnectionLifetime: .milliseconds(100),
            preflightPing: false,
            evictionInterval: .milliseconds(50)
        )
        let pool = try await ClickHouseConnectionPool(configuration: configuration)
        try await Task.sleep(for: .milliseconds(500))
        let stats = await pool.stats()
        #expect(stats.evictedByLifetime >= 1)
        await pool.close()
    }
}
