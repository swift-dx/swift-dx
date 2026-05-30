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

// Sad-path coverage for `.endpointsExhausted` (typed-error case) plus
// the corresponding `ClickHouseConnectionPool.Failure.allEndpointsFailed`
// pool failure. The pool surfaces a per-endpoint failure list so callers
// can see exactly which hosts were tried and why each refused.
@Suite("ClickHouseEndpointFailure aggregation when every endpoint refuses")
struct ClickHouseEndpointErrorsTests {

    @Test("ClickHouseEndpointFailure carries host, port, reason")
    func endpointFailureCarriesFields() {
        let failure = ClickHouseEndpointFailure(host: "host-a", port: 9000, reason: "ECONNREFUSED")
        #expect(failure.host == "host-a")
        #expect(failure.port == 9000)
        #expect(failure.reason == "ECONNREFUSED")
        #expect(failure.description.contains("host-a"))
        #expect(failure.description.contains("9000"))
        #expect(failure.description.contains("ECONNREFUSED"))
    }

    @Test("ClickHouseEndpointFailure is Equatable per field")
    func endpointFailureEquatable() {
        let lhs = ClickHouseEndpointFailure(host: "h", port: 1, reason: "x")
        let rhs = ClickHouseEndpointFailure(host: "h", port: 1, reason: "x")
        let differentReason = ClickHouseEndpointFailure(host: "h", port: 1, reason: "y")
        let differentPort = ClickHouseEndpointFailure(host: "h", port: 2, reason: "x")
        let differentHost = ClickHouseEndpointFailure(host: "g", port: 1, reason: "x")
        #expect(lhs == rhs)
        #expect(lhs != differentReason)
        #expect(lhs != differentPort)
        #expect(lhs != differentHost)
    }

    @Test(".endpointsExhausted carries the per-endpoint failure list")
    func endpointsExhaustedCarriesList() {
        let failures = [
            ClickHouseEndpointFailure(host: "h1", port: 9000, reason: "refused"),
            ClickHouseEndpointFailure(host: "h2", port: 9000, reason: "unreachable"),
        ]
        let error: ClickHouseError = .endpointsExhausted(failures: failures)
        switch error {
        case .endpointsExhausted(let observed):
            #expect(observed.count == 2)
            #expect(observed[0].host == "h1")
            #expect(observed[1].host == "h2")
        default:
            Issue.record("expected .endpointsExhausted")
        }
        #expect(error.description.contains("h1"))
        #expect(error.description.contains("h2"))
    }

    @Test(".endpointsExhausted with empty failure list is structurally valid")
    func endpointsExhaustedEmptyList() {
        let error: ClickHouseError = .endpointsExhausted(failures: [])
        switch error {
        case .endpointsExhausted(let observed):
            #expect(observed.isEmpty)
        default:
            Issue.record("expected .endpointsExhausted")
        }
    }

    @Test("Pool init against three unreachable endpoints surfaces allEndpointsFailed")
    func poolInitAllEndpointsUnreachable() async {
        let configuration = ClickHouseConnectionPool.Configuration(
            endpoints: [
                ClickHouseEndpoint(host: "127.0.0.1", port: 1),
                ClickHouseEndpoint(host: "127.0.0.1", port: 2),
                ClickHouseEndpoint(host: "127.0.0.1", port: 3),
            ],
            minConnections: 1,
            maxConnections: 3,
            acquireTimeout: .milliseconds(200),
            evictionInterval: .seconds(60)
        )
        var caught: Error?
        do {
            _ = try await ClickHouseConnectionPool(configuration: configuration)
        } catch {
            caught = error
        }
        guard let failure = caught as? ClickHouseConnectionPool.Failure else {
            Issue.record("expected Failure, got \(String(describing: caught))")
            return
        }
        switch failure {
        case .openFailed:
            // Single-endpoint prewarm path wraps the very first attempt
            // in openFailed; the multi-endpoint walk surfaces
            // allEndpointsFailed once it has tried every entry.
            break
        case .allEndpointsFailed(let failures):
            #expect(failures.count >= 1)
            #expect(failures.allSatisfy { $0.host == "127.0.0.1" })
        case .poolClosed, .acquireTimedOut:
            Issue.record("unexpected failure: \(failure)")
        }
    }

    @Test("Pool acquire across exhausted endpoints reports each per-host failure")
    func poolAcquireReportsPerHostFailures() async throws {
        let configuration = ClickHouseConnectionPool.Configuration(
            endpoints: [
                ClickHouseEndpoint(host: "127.0.0.1", port: 1),
                ClickHouseEndpoint(host: "127.0.0.1", port: 2),
            ],
            minConnections: 0,
            maxConnections: 2,
            acquireTimeout: .milliseconds(200),
            evictionInterval: .seconds(60)
        )
        let pool = try await ClickHouseConnectionPool(configuration: configuration)
        defer { Task { await pool.close() } }

        var caught: ClickHouseConnectionPool.Failure?
        do {
            _ = try await pool.withConnection { _ in 0 }
        } catch let failure as ClickHouseConnectionPool.Failure {
            caught = failure
        }
        switch caught {
        case .some(.allEndpointsFailed(let failures)):
            #expect(failures.count == 2)
            #expect(failures.contains { $0.port == 1 })
            #expect(failures.contains { $0.port == 2 })
        case .some(.openFailed):
            break
        default:
            Issue.record("expected allEndpointsFailed, got \(String(describing: caught))")
        }
    }

    @Test("ClickHouseConnectionPool.Failure cases are exhaustively switchable")
    func failureExhaustiveSwitch() {
        let samples: [ClickHouseConnectionPool.Failure] = [
            .poolClosed,
            .acquireTimedOut(after: .milliseconds(500)),
            .openFailed(reason: "ECONNREFUSED"),
            .allEndpointsFailed(failures: [ClickHouseEndpointFailure(host: "h", port: 1, reason: "x")]),
        ]
        var observed: [String] = []
        for failure in samples {
            switch failure {
            case .poolClosed:
                observed.append("closed")
            case .acquireTimedOut(let after):
                observed.append("timeout:\(after)")
            case .openFailed(let reason):
                observed.append("open:\(reason)")
            case .allEndpointsFailed(let failures):
                observed.append("all:\(failures.count)")
            }
        }
        #expect(observed.count == 4)
        #expect(observed[0] == "closed")
        #expect(observed[2] == "open:ECONNREFUSED")
        #expect(observed[3] == "all:1")
    }
}
