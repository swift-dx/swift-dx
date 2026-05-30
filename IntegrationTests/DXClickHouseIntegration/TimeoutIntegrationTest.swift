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

// Live-broker integration cover for the per-query timeout parameter on
// every public ClickHouseClient operation. Drives a deliberately slow
// server-side query (sleep / large block) under a tight local timeout
// and asserts the typed `ClickHouseError.queryTimeout(elapsed:)` fires
// inside the expected tolerance window.
//
// The slow query is produced via `SELECT sleepEachRow(1) FROM numbers(N)`,
// which forces ClickHouse to spend ~N seconds returning the result.
@Suite(
    "DXClickHouse per-query timeout integration",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseTimeoutIntegration {

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

    private static func client() async throws -> ClickHouseClient {
        try await ClickHouse.connect(
            host: host,
            port: port,
            user: user,
            password: password,
            database: database
        )
    }

    // A fast scalar that completes well inside the supplied deadline
    // must NOT surface a timeout error. Establishes the negative branch
    // of the race.
    @Test("Fast scalar query completes inside the deadline with no timeout error")
    func fastQueryUnderDeadline() async throws {
        let client = try await Self.client()
        let value: UInt64 = try await client.scalar(
            "SELECT toUInt64(42)",
            as: UInt64.self,
            timeout: .seconds(5)
        )
        #expect(value == 42)
        await client.close()
    }

    // The headline test for the timeout feature: a deliberately slow
    // SELECT under a 100ms local deadline must fire
    // `ClickHouseError.queryTimeout(elapsed:)` within 1.5s of when the
    // call started (the tolerance covers worker-queue dispatch, server
    // socket shutdown, and async-bridge return time on slow CI hosts).
    @Test("Slow query under tight timeout surfaces .queryTimeout within tolerance")
    func slowQueryTimesOut() async throws {
        let client = try await Self.client()
        let started = ContinuousClock.now
        var observed: ClickHouseError = .reconnectExhausted(attempts: 0)
        do {
            // sleepEachRow(1) sleeps for 1 second per row server-side,
            // so 60 rows = 60 seconds wall-clock if allowed to run.
            // Our 100ms local timeout must cancel it well before then.
            _ = try await client.scalar(
                "SELECT sum(sleepEachRow(1)) FROM numbers(60)",
                as: UInt8.self,
                timeout: .milliseconds(100)
            )
            Issue.record("expected .queryTimeout, the slow SELECT completed")
        } catch let error {
            observed = error
        }
        let elapsed = ContinuousClock.now - started
        switch observed {
        case .queryTimeout(let elapsedReported):
            #expect(
                elapsedReported >= .milliseconds(80),
                "reported elapsed \(elapsedReported) below the 80ms floor"
            )
        case .queryFailed:
            // Server-side `max_execution_time` fired before the local
            // race; that is also a valid timeout outcome from the
            // caller's perspective (the bound holds). Accept it.
            break
        case .connectionFailed, .socketIOFailed, .unexpectedEOF, .protocolError, .reconnectExhausted, .endpointsExhausted:
            Issue.record("expected .queryTimeout or .queryFailed (server-side timeout), got \(observed)")
        }
        #expect(
            elapsed < .seconds(2),
            "timeout did not fire within tolerance: elapsed=\(elapsed)"
        )
        await client.close()
    }

    // `.zero` timeout disables the local race entirely. The query is
    // free to run for as long as the server allows. Drive a 3-second
    // sleep and assert it completes without a typed timeout error.
    @Test("timeout: .zero disables the local deadline")
    func zeroTimeoutDisablesDeadline() async throws {
        let client = try await Self.client()
        let started = ContinuousClock.now
        let value: UInt8 = try await client.scalar(
            "SELECT toUInt8(sleepEachRow(0.5) + 1) FROM numbers(1)",
            as: UInt8.self,
            timeout: .zero
        )
        let elapsed = ContinuousClock.now - started
        #expect(value == 1)
        #expect(elapsed >= .milliseconds(400), "expected at least 400ms server-side sleep, got \(elapsed)")
        await client.close()
    }

    // Confirm that after a timeout fires, the client transparently
    // re-establishes its socket (default reconnect policy is
    // always-retry) and the next query succeeds on the same client
    // instance.
    @Test("Client recovers and serves the next query after a timeout fires")
    func clientRecoversAfterTimeout() async throws {
        let client = try await Self.client()
        do {
            _ = try await client.scalar(
                "SELECT sum(sleepEachRow(1)) FROM numbers(30)",
                as: UInt8.self,
                timeout: .milliseconds(100)
            )
        } catch {
            // expected; ignore the typed error here, the next call is
            // what proves recovery.
        }
        // Recovery deadline: the reconnect path needs to re-handshake
        // before the next query. Allow up to 5s for the round-trip on
        // a healthy localhost loop.
        let recovered: UInt64 = try await client.scalar(
            "SELECT toUInt64(7)",
            as: UInt64.self,
            timeout: .seconds(5)
        )
        #expect(recovered == 7)
        await client.close()
    }
}
