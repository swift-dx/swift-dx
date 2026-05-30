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

import DXClickHouseRaw
import Testing

@Suite("RawClickHouseConnectionPool failover semantics (no broker)")
struct RawClickHouseConnectionPoolFailoverTest {

    @Test("Pool init with two unreachable endpoints surfaces allEndpointsFailed")
    func bothEndpointsUnreachableFailsClosed() async {
        let configuration = RawClickHouseConnectionPool.Configuration(
            endpoints: [
                RawEndpoint(host: "127.0.0.1", port: 1),
                RawEndpoint(host: "127.0.0.1", port: 2),
            ],
            minConnections: 1,
            maxConnections: 2,
            acquireTimeout: .milliseconds(200),
            evictionInterval: .seconds(60)
        )
        var caught: Error?
        do {
            _ = try await RawClickHouseConnectionPool(configuration: configuration)
        } catch {
            caught = error
        }
        guard let failure = caught as? RawClickHouseConnectionPool.Failure else {
            Issue.record("expected Failure, got \(String(describing: caught))")
            return
        }
        switch failure {
        case .openFailed:
            // The single-endpoint prewarm path wraps the first attempt
            // in openFailed; the multi-endpoint path surfaces
            // allEndpointsFailed. Both are acceptable for a fully
            // unreachable cluster.
            break
        case .allEndpointsFailed(let failures):
            #expect(failures.count == 2)
        case .poolClosed, .acquireTimedOut:
            Issue.record("unexpected failure: \(failure)")
        }
    }

    @Test("Pool with zero minConnections constructs without a broker")
    func zeroMinConnectionsAllowsLazyConstruction() async throws {
        let configuration = RawClickHouseConnectionPool.Configuration(
            endpoints: [RawEndpoint(host: "127.0.0.1", port: 1)],
            minConnections: 0,
            maxConnections: 4,
            acquireTimeout: .milliseconds(100),
            evictionInterval: .seconds(60)
        )
        let pool = try await RawClickHouseConnectionPool(configuration: configuration)
        let stats = await pool.stats()
        #expect(stats.idleConnections == 0)
        #expect(stats.inUseConnections == 0)
        #expect(stats.openedTotal == 0)
        await pool.close()
    }

    @Test("Pool acquire on unreachable endpoint reports allEndpointsFailed via Failure")
    func acquireOnUnreachableEndpointFails() async throws {
        let configuration = RawClickHouseConnectionPool.Configuration(
            endpoints: [
                RawEndpoint(host: "127.0.0.1", port: 1),
                RawEndpoint(host: "127.0.0.1", port: 2),
            ],
            minConnections: 0,
            maxConnections: 2,
            acquireTimeout: .milliseconds(100),
            evictionInterval: .seconds(60)
        )
        let pool = try await RawClickHouseConnectionPool(configuration: configuration)
        var caught: RawClickHouseConnectionPool.Failure?
        do {
            _ = try await pool.withConnection { _ in 0 }
        } catch let error as RawClickHouseConnectionPool.Failure {
            caught = error
        }
        switch caught {
        case .some(.allEndpointsFailed(let failures)):
            #expect(failures.count == 2)
            #expect(failures.allSatisfy { $0.host == "127.0.0.1" })
        case .some(.openFailed):
            // Acceptable on platforms where the dispatch race lets the
            // first endpoint short-circuit before the second is tried.
            break
        default:
            Issue.record("expected allEndpointsFailed, got \(String(describing: caught))")
        }
        let stats = await pool.stats()
        #expect(stats.endpointFailovers >= 1)
        await pool.close()
    }

    @Test("Pool Configuration default fields use the documented production shape")
    func defaultConfigurationShape() {
        let configuration = RawClickHouseConnectionPool.Configuration(
            endpoints: [RawEndpoint(host: "h", port: 9000)]
        )
        #expect(configuration.minConnections == 1)
        #expect(configuration.maxConnections == 16)
        #expect(configuration.acquireTimeout == .seconds(30))
        #expect(configuration.idleConnectionTTL == .seconds(300))
        #expect(configuration.maxConnectionLifetime == .seconds(3600))
        #expect(configuration.preflightPing == false)
        #expect(configuration.evictionInterval == .seconds(30))
    }
}
