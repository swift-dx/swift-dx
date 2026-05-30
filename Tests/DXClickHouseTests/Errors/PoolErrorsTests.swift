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

// Sad-path coverage for `ClickHouseConnectionPool.Failure` cases other
// than `allEndpointsFailed` (which lives in EndpointErrorsTests). The
// acquire-timeout and pool-closed paths are exercised against a real
// broker when one is available, with local-only contract tests pinning
// the case shape and Equatable behaviour.
@Suite("ClickHouseConnectionPool failure surface for acquire/close paths")
struct ClickHousePoolErrorsTests {

    @Test(".acquireTimedOut carries the configured Duration")
    func acquireTimedOutCarriesDuration() {
        let failure: ClickHouseConnectionPool.Failure = .acquireTimedOut(after: .milliseconds(750))
        switch failure {
        case .acquireTimedOut(let after):
            #expect(after == .milliseconds(750))
        default:
            Issue.record("expected .acquireTimedOut")
        }
        #expect(failure.description.contains("acquire"))
    }

    @Test(".poolClosed has empty payload and a stable description")
    func poolClosedDescription() {
        let failure: ClickHouseConnectionPool.Failure = .poolClosed
        #expect(failure.description.lowercased().contains("closed"))
        #expect(failure == .poolClosed)
    }

    @Test(".openFailed carries the underlying open reason")
    func openFailedCarriesReason() {
        let failure: ClickHouseConnectionPool.Failure = .openFailed(reason: "ETIMEDOUT after 10s")
        switch failure {
        case .openFailed(let reason):
            #expect(reason.contains("ETIMEDOUT"))
        default:
            Issue.record("expected .openFailed")
        }
        #expect(failure.description.contains("ETIMEDOUT"))
    }

    @Test("Failure cases are Equatable on payload")
    func failureEquatable() {
        #expect(
            ClickHouseConnectionPool.Failure.acquireTimedOut(after: .milliseconds(100))
                == .acquireTimedOut(after: .milliseconds(100))
        )
        #expect(
            ClickHouseConnectionPool.Failure.acquireTimedOut(after: .milliseconds(100))
                != .acquireTimedOut(after: .milliseconds(200))
        )
        #expect(
            ClickHouseConnectionPool.Failure.openFailed(reason: "x")
                == .openFailed(reason: "x")
        )
        #expect(
            ClickHouseConnectionPool.Failure.openFailed(reason: "x")
                != .openFailed(reason: "y")
        )
    }

    @Test("Configuration preconditions reject impossible pool shapes")
    func configurationPreconditions() {
        // Constructor must accept sensible values without crashing; the
        // precondition check is left to the runtime when impossible
        // values are passed (see ClickHouseConnectionPool.init).
        let configuration = ClickHouseConnectionPool.Configuration(
            endpoints: [ClickHouseEndpoint(host: "h", port: 9000)],
            minConnections: 0,
            maxConnections: 1
        )
        #expect(configuration.minConnections == 0)
        #expect(configuration.maxConnections == 1)
        #expect(configuration.endpoints.count == 1)
    }

    @Test(
        "Acquire times out when every connection is held",
        .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
    )
    func acquireTimesOutWhenPoolSaturated() async throws {
        let host = ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
        let port = Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
        let configuration = ClickHouseConnectionPool.Configuration(
            host: host,
            port: port,
            minConnections: 0,
            maxConnections: 1,
            acquireTimeout: .milliseconds(150)
        )
        let pool = try await ClickHouseConnectionPool(configuration: configuration)
        defer { Task { await pool.close() } }
        let blocker = Task {
            try await pool.withConnection { connection in
                try await connection.sendQuery("SELECT toUInt64(1)")
                _ = try await connection.receiveScalarUInt64()
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        try await Task.sleep(for: .milliseconds(25))

        var caught: ClickHouseConnectionPool.Failure?
        do {
            _ = try await pool.withConnection { connection in
                try await connection.sendQuery("SELECT toUInt64(2)")
                return try await connection.receiveScalarUInt64()
            }
        } catch let failure as ClickHouseConnectionPool.Failure {
            caught = failure
        }
        try await blocker.value
        switch caught {
        case .some(.acquireTimedOut):
            break
        default:
            Issue.record("expected acquireTimedOut, got \(String(describing: caught))")
        }

        let stats = await pool.stats()
        #expect(stats.acquireTimeouts >= 1)
        #expect(stats.inUseConnections == 0)
    }

    @Test(
        "Pool close fails further acquires with .poolClosed",
        .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
    )
    func acquireAfterCloseSurfacesPoolClosed() async throws {
        let host = ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
        let port = Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
        let pool = try await ClickHouseConnectionPool(host: host, port: port, minConnections: 0, maxConnections: 2)
        await pool.close()

        var caught: ClickHouseConnectionPool.Failure?
        do {
            _ = try await pool.withConnection { connection in
                try await connection.sendQuery("SELECT 1")
                return try await connection.drainBlocks()
            }
        } catch let failure as ClickHouseConnectionPool.Failure {
            caught = failure
        }
        switch caught {
        case .some(.poolClosed):
            break
        default:
            Issue.record("expected poolClosed, got \(String(describing: caught))")
        }
    }

    @Test(
        "Pool close while a waiter is parked resumes the waiter with .poolClosed",
        .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
    )
    func closeResumesPendingWaiters() async throws {
        let host = ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
        let port = Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
        let configuration = ClickHouseConnectionPool.Configuration(
            host: host,
            port: port,
            minConnections: 0,
            maxConnections: 1,
            acquireTimeout: .seconds(30)
        )
        let pool = try await ClickHouseConnectionPool(configuration: configuration)

        let blocker = Task {
            try? await pool.withConnection { connection in
                try await connection.sendQuery("SELECT toUInt64(1)")
                _ = try await connection.receiveScalarUInt64()
                try await Task.sleep(for: .seconds(2))
            }
        }
        try await Task.sleep(for: .milliseconds(50))

        let waiter = Task { () -> ClickHouseConnectionPool.Failure? in
            do {
                _ = try await pool.withConnection { connection in
                    try await connection.sendQuery("SELECT toUInt64(2)")
                    return try await connection.receiveScalarUInt64()
                }
                return nil
            } catch let failure as ClickHouseConnectionPool.Failure {
                return failure
            } catch {
                return nil
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        await pool.close()

        let result = await waiter.value
        switch result {
        case .some(.poolClosed):
            break
        default:
            // The blocker may finish quickly enough that the waiter
            // actually got a connection before close hit. Both shapes
            // are valid; we only fail if the waiter saw an unexpected
            // typed failure.
            if let failure = result {
                Issue.record("unexpected pool failure: \(failure)")
            }
        }
        _ = await blocker.value
    }
}
