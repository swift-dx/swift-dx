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

// Drives `ClickHouseClient.ping` across every supported timeout shape.
// Covers the default (no timeout argument), a generous timeout, a tight
// but reasonable timeout, `.zero` (disables the local race), and the
// callback overload. Each test runs end-to-end against a live broker
// and asserts the call returns without raising a typed error.
@Suite(
    "DXClickHouse OperationsCoverage: ping with timeout variations",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct PingCoverageIT {

    @Test("ping() with no explicit timeout succeeds against a healthy broker")
    func pingDefault() async throws {
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.ping()
    }

    @Test("ping(timeout: .seconds(5)) succeeds well inside the deadline")
    func pingGenerousTimeout() async throws {
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.ping(timeout: .seconds(5))
    }

    @Test("ping(timeout: .milliseconds(200)) succeeds for localhost round-trip")
    func pingTightTimeout() async throws {
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.ping(timeout: .milliseconds(200))
    }

    @Test("ping(timeout: .zero) disables the local deadline and still succeeds")
    func pingZeroTimeout() async throws {
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.ping(timeout: .zero)
    }

    @Test("ping(completion:) delivers Result.success on a healthy broker")
    func pingCallback() async throws {
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        let outcome: ClickHouseError? = await withCheckedContinuation { continuation in
            client.ping { result in
                switch result {
                case .success: continuation.resume(returning: nil)
                case .failure(let error): continuation.resume(returning: error)
                }
            }
        }
        #expect(outcome == nil)
    }

    @Test("ping is usable after a normal scalar query on the same client")
    func pingAfterQuery() async throws {
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        let value: UInt64 = try await client.scalar("SELECT toUInt64(7)", as: UInt64.self)
        #expect(value == 7)
        try await client.ping()
    }

    @Test("ping is usable before issuing any other query on a fresh client")
    func pingBeforeAnyQuery() async throws {
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.ping()
        let value: UInt64 = try await client.scalar("SELECT toUInt64(11)", as: UInt64.self)
        #expect(value == 11)
    }

    @Test("ten consecutive ping() round-trips succeed without leaking the connection")
    func pingTenInARow() async throws {
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        for _ in 0..<10 {
            try await client.ping(timeout: .seconds(2))
        }
        let value: UInt64 = try await client.scalar("SELECT toUInt64(99)", as: UInt64.self)
        #expect(value == 99)
    }
}
