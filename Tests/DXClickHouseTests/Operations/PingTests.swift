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

@Suite(
    "ClickHouseClient ping happy paths",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseClientPingTests {

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

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(
            host: host,
            port: port,
            user: user,
            password: password,
            database: database
        )
    }

    @Test("ping() succeeds against a live broker")
    func pingSucceeds() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.ping()
    }

    @Test("ping(timeout:) succeeds with an explicit deadline")
    func pingWithTimeoutOverride() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.ping(timeout: .seconds(2))
    }

    @Test("ping(timeout: .zero) succeeds without a local deadline")
    func pingWithZeroTimeout() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.ping(timeout: .zero)
    }

    @Test("ping() fails fast against an unreachable port")
    func pingFailsAgainstUnreachable() async {
        var caught: ClickHouseError = .reconnectExhausted(attempts: 0)
        var didThrow = false
        do {
            let client = try await ClickHouseClient(host: "127.0.0.1", port: 1)
            await client.close()
        } catch {
            caught = error
            didThrow = true
        }
        #expect(didThrow)
        switch caught {
        case .connectionFailed, .socketIOFailed, .reconnectExhausted, .endpointsExhausted:
            break
        default:
            Issue.record("expected connection failure error, got \(caught)")
        }
    }

    @Test("ping succeeds repeatedly on the same client")
    func pingRepeatable() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        for _ in 0..<3 {
            try await client.ping()
        }
    }
}

