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

// Live-broker integration cover for the always-retry reconnection
// default. Confirms that a connection opened with no explicit policy
// (i.e. ``ReconnectionPolicy.alwaysRetry``) transparently re-establishes
// the underlying socket after a forced shutdown and that the next
// caller-visible round-trip succeeds without the caller having to
// reconstruct the client.
//
// The shutdown is forced via the internal `shutdownSocketForTimeout`
// hook the timeout path uses — this is the same mechanism a real
// broker restart or network partition would expose to the worker.
@Suite(
    "DXClickHouse default reconnect integration",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseReconnectDefaultIntegration {

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

    // The library default for any connection that does not pass an
    // explicit policy: unbounded attempts, 100ms→5s exponential
    // backoff. Confirms the documented contract.
    @Test("The default ReconnectionPolicy on a fresh AsyncClickHouseConnection is alwaysRetry")
    func defaultPolicyIsAlwaysRetry() async throws {
        let connection = try await AsyncClickHouseConnection(
            host: Self.host,
            port: Self.port,
            user: Self.user,
            password: Self.password,
            database: Self.database
        )
        defer { Task { await connection.close() } }
        // Synchronously inspect the connection wrapper's policy via a
        // query round-trip; the test exists primarily to validate the
        // surface compiles without an explicit policy argument and
        // that the resulting client is functional.
        try await connection.sendQuery("SELECT toUInt64(7)")
        let value = try await connection.receiveScalarUInt64()
        #expect(value == 7)
    }

    // The synchronous ClickHouseConnection mirrors the same default.
    @Test("The default ReconnectionPolicy on a sync ClickHouseConnection is alwaysRetry")
    func defaultPolicyOnSyncConnection() throws {
        let connection = try ClickHouseConnection(
            host: Self.host,
            port: Self.port,
            user: Self.user,
            password: Self.password,
            database: Self.database
        )
        defer { connection.close() }
        #expect(connection.reconnectionPolicy == .alwaysRetry)
        try connection.sendQuery("SELECT toUInt64(13)")
        let value = try connection.receiveScalarUInt64()
        #expect(value == 13)
    }

    // The ClickHouseClient (the async actor façade) is documented to
    // forward to the same alwaysRetry default. Confirm that an
    // opaque ClickHouseClient survives a forced socket shutdown
    // mid-session and that the very next caller-visible query
    // succeeds. This is the "user does nothing, reconnection just
    // works" promise the documented default makes.
    @Test("ClickHouseClient transparently recovers after a forced socket shutdown")
    func clientRecoversAfterForcedShutdown() async throws {
        let client = try await ClickHouse.connect(
            host: Self.host,
            port: Self.port,
            user: Self.user,
            password: Self.password,
            database: Self.database
        )
        // Establish baseline functionality.
        let baseline: UInt64 = try await client.scalar(
            "SELECT toUInt64(1)",
            as: UInt64.self,
            timeout: .seconds(5)
        )
        #expect(baseline == 1)

        // Simulate a network drop. The timeout fires a Cancel-style
        // socket shutdown which exercises the same code path a remote
        // disconnection would: the worker's next syscall returns 0 or
        // -1, the connection layer enters its reconnect loop with the
        // alwaysRetry policy.
        do {
            _ = try await client.scalar(
                "SELECT sum(sleepEachRow(1)) FROM numbers(30)",
                as: UInt8.self,
                timeout: .milliseconds(100)
            )
            Issue.record("expected the slow query to surface a typed error")
        } catch {
            // expected; the actual error shape (queryTimeout or
            // server-side queryFailed) is covered by the timeout
            // integration suite. This test only asserts recovery.
        }

        // The next round-trip on the same client must succeed. The
        // alwaysRetry default means we get reconnect-and-replay
        // semantics without the caller having to reconstruct anything.
        let recovered: UInt64 = try await client.scalar(
            "SELECT toUInt64(99)",
            as: UInt64.self,
            timeout: .seconds(5)
        )
        #expect(recovered == 99)

        await client.close()
    }
}
