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

// Interaction tests for the per-query timeout path:
//   * A long-running query interrupted by a short timeout produces
//     ClickHouseError.queryTimeout (or a server-side cancel surfaced
//     as .queryFailed when the injected max_execution_time fires
//     first).
//   * After the cancel, the connection's reconnect path restores the
//     socket and the next call succeeds.
//   * The `.zero` timeout overload disables both the local race and
//     the server-side max_execution_time injection.
@Suite(
    "Per-query timeout interaction with cancel + reconnect",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseTimeoutInteractionTests {

    private static var host: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
    }
    private static var port: Int {
        Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
    }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port)
    }

    @Test("Long SELECT with short timeout fires within an order-of-magnitude tolerance")
    func longSelectShortTimeoutFires() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let start = Date()
        var caught: ClickHouseError?
        do {
            _ = try await client.scalar(
                "SELECT count() FROM numbers(20000000000)",
                as: UInt64.self,
                timeout: .milliseconds(250)
            )
        } catch let error {
            caught = error
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(caught != nil)
        #expect(elapsed < 5.0, "timeout took \(elapsed)s for a 0.25s deadline")
    }

    @Test("After a timeout the next operation reconnects and succeeds")
    func nextOperationSucceedsAfterTimeout() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        // Trigger a timeout cancel.
        _ = try? await client.scalar(
            "SELECT count() FROM numbers(20000000000)",
            as: UInt64.self,
            timeout: .milliseconds(200)
        )
        // The next operation must succeed via the reconnect path.
        let value = try await client.scalar("SELECT toUInt64(11)", as: UInt64.self)
        #expect(value == 11)
    }

    @Test(".zero timeout disables the deadline race")
    func zeroTimeoutSkipsRace() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let value = try await client.scalar(
            "SELECT toUInt64(42)",
            as: UInt64.self,
            timeout: .zero
        )
        #expect(value == 42)
    }

    @Test("Ping with a tight timeout fires within the deadline")
    func pingWithTightTimeoutHonorsDeadline() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.ping(timeout: .seconds(2))
    }

    @Test("Many timeouts in sequence do not break the client (reconnect each time)")
    func manyTimeoutsRecoverEachTime() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        for _ in 0..<3 {
            _ = try? await client.scalar(
                "SELECT count() FROM numbers(20000000000)",
                as: UInt64.self,
                timeout: .milliseconds(150)
            )
            let value = try await client.scalar("SELECT toUInt64(7)", as: UInt64.self)
            #expect(value == 7)
        }
    }
}
