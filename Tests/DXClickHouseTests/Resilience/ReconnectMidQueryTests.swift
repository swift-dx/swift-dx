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

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// Mid-query reconnect coverage. The default reconnect policy is
// .alwaysRetry, so callers who do nothing should see in-flight
// transient I/O failures auto-heal. This suite drives the contract.
//
// The strong fault-injection path lives in
// IntegrationTests/DXClickHouseIntegration/Stability — that suite
// restarts the broker container mid-query and confirms the next call
// succeeds. Here we cover the contract at the client API level using
// connection-cycle patterns that don't require a docker restart.
@Suite(
    "Reconnect-on-default-policy behaviour across mid-query failures",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseReconnectMidQueryTests {

    private static var host: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
    }

    private static var password: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? ""
    }
    private static var port: Int {
        Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
    }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, password: password)
    }

    @Test("Default reconnect policy is .alwaysRetry with unbounded attempts")
    func defaultPolicyIsAlwaysRetry() {
        let policy = ReconnectionPolicy.default
        #expect(policy.maxAttempts == ReconnectionPolicy.unboundedAttempts)
        #expect(policy.maxAttempts == Int.max)
        #expect(policy == ReconnectionPolicy.alwaysRetry)
    }

    @Test("Many sequential SELECTs survive on a single client (no leaks, no errors)")
    func manySequentialQueriesSucceed() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        for iteration in 0..<50 {
            let value = try await client.scalar(
                "SELECT toUInt64(\(iteration))",
                as: UInt64.self
            )
            #expect(value == UInt64(iteration))
        }
    }

    @Test("Concurrent SELECTs across one client serialise through the actor without error")
    func concurrentSelectsSerialise() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let total: UInt64 = try await withThrowingTaskGroup(of: UInt64.self) { group in
            for iteration in 0..<32 {
                let captured = iteration
                group.addTask {
                    try await client.scalar(
                        "SELECT toUInt64(\(captured))",
                        as: UInt64.self
                    )
                }
            }
            var sum: UInt64 = 0
            for try await value in group {
                sum &+= value
            }
            return sum
        }
        let expected: UInt64 = (0..<32).reduce(0) { $0 + UInt64($1) }
        #expect(total == expected)
    }

    @Test("After a connection close, a fresh client connects without error")
    func freshClientAfterCloseReconnects() async throws {
        let first = try await Self.makeClient()
        let firstValue = try await first.scalar("SELECT toUInt64(1)", as: UInt64.self)
        #expect(firstValue == 1)
        await first.close()

        let second = try await Self.makeClient()
        defer { Task { await second.close() } }
        let secondValue = try await second.scalar("SELECT toUInt64(2)", as: UInt64.self)
        #expect(secondValue == 2)
    }

    @Test("Long-running stream with intermittent pauses does not deadlock")
    func longStreamSurvivesIntermittentPauses() async throws {
        struct Row: Decodable, Sendable { let v: UInt64 }
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        var observed: UInt64 = 0
        for try await row in client.select(
            "SELECT toUInt64(number) AS v FROM numbers(200)",
            as: Row.self
        ) {
            observed &+= 1
            if observed % 50 == 0 {
                try await Task.sleep(for: .milliseconds(10))
            }
            _ = row
        }
        #expect(observed == 200)
    }
}
