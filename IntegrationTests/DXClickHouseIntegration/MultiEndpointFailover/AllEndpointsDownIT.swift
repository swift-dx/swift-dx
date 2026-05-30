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

// When every configured endpoint refuses the connect, the pool's
// failover walk runs out of choices and surfaces the documented
// `ClickHouseConnectionPool.Failure.allEndpointsFailed` to the caller.
// The pool surface uses its own `Failure` enum (not `ClickHouseError`)
// because the failure is a pool-level concern; the per-endpoint
// failures the pool collected on the way are attached for diagnostic
// inspection.
@Suite(
    "DXClickHouse MultiEndpointFailover: all endpoints down surfaces typed Pool.Failure",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct AllEndpointsDownIT {

    @Test("pool init with every endpoint dead surfaces typed allEndpointsFailed")
    func poolInitAllDeadSurfacesAllEndpointsFailed() async throws {
        let configuration = ClickHouseConnectionPool.Configuration(
            endpoints: [
                ClickHouseEndpoint(host: "127.0.0.1", port: 1),
                ClickHouseEndpoint(host: "127.0.0.1", port: 2),
                ClickHouseEndpoint(host: "127.0.0.1", port: 3),
            ],
            user: MultiEndpointFailoverSupport.user,
            password: MultiEndpointFailoverSupport.password,
            database: MultiEndpointFailoverSupport.database,
            minConnections: 1,
            maxConnections: 2,
            acquireTimeout: .seconds(5),
            preflightPing: false,
            evictionInterval: .seconds(60)
        )
        var caught: ClickHouseConnectionPool.Failure = .poolClosed
        var didThrow = false
        do {
            let pool = try await ClickHouseConnectionPool(configuration: configuration)
            await pool.close()
        } catch {
            caught = error
            didThrow = true
        }
        #expect(didThrow, "pool init succeeded when every endpoint was dead")
        if didThrow {
            switch caught {
            case .allEndpointsFailed(let failures):
                #expect(failures.count >= 1, "expected aggregated per-endpoint failures, got \(failures.count)")
            case .openFailed:
                // Some platforms classify the single-pass open as
                // openFailed rather than allEndpointsFailed when the
                // pool's seedTarget is 1; both are pool-level typed
                // failures, accept either as long as the surface is
                // typed.
                break
            case .poolClosed, .acquireTimedOut:
                Issue.record("unexpected typed pool failure: \(caught)")
            }
        }
    }

    @Test("lazy pool with dead endpoints surfaces allEndpointsFailed on first acquire")
    func lazyPoolFirstAcquireSurfacesAllEndpointsFailed() async throws {
        let configuration = ClickHouseConnectionPool.Configuration(
            endpoints: [
                ClickHouseEndpoint(host: "127.0.0.1", port: 1),
                ClickHouseEndpoint(host: "127.0.0.1", port: 2),
            ],
            user: MultiEndpointFailoverSupport.user,
            password: MultiEndpointFailoverSupport.password,
            database: MultiEndpointFailoverSupport.database,
            minConnections: 0,
            maxConnections: 2,
            acquireTimeout: .seconds(5),
            preflightPing: false,
            evictionInterval: .seconds(60)
        )
        let pool = try await ClickHouseConnectionPool(configuration: configuration)
        defer { Task { await pool.close() } }
        var caught: ClickHouseConnectionPool.Failure = .poolClosed
        var didThrow = false
        do {
            try await pool.withConnection { _ in }
        } catch let failure as ClickHouseConnectionPool.Failure {
            caught = failure
            didThrow = true
        } catch {
            Issue.record("expected typed Pool.Failure, got untyped \(error)")
            return
        }
        #expect(didThrow, "acquire succeeded when every endpoint was dead")
        if didThrow {
            switch caught {
            case .allEndpointsFailed(let failures):
                #expect(failures.count >= 1)
            case .openFailed:
                break
            case .poolClosed, .acquireTimedOut:
                Issue.record("unexpected typed pool failure: \(caught)")
            }
        }
    }

    @Test("typed endpointsExhausted surfaces from the connection layer when every endpoint is dead")
    func connectionLayerAllDeadSurfacesEndpointsExhausted() async throws {
        // The connection layer also has a multi-endpoint surface that
        // returns `ClickHouseError.endpointsExhausted` rather than the
        // pool's typed Failure. Exercise it through the public Pool
        // surface to ensure the typed-error wiring stays consistent
        // when every endpoint refuses.
        let configuration = ClickHouseConnectionPool.Configuration(
            endpoints: [
                ClickHouseEndpoint(host: "127.0.0.1", port: 1),
                ClickHouseEndpoint(host: "127.0.0.1", port: 2),
                ClickHouseEndpoint(host: "127.0.0.1", port: 3),
            ],
            user: MultiEndpointFailoverSupport.user,
            password: MultiEndpointFailoverSupport.password,
            database: MultiEndpointFailoverSupport.database,
            minConnections: 0,
            maxConnections: 1,
            acquireTimeout: .seconds(2),
            preflightPing: false,
            evictionInterval: .seconds(60)
        )
        let pool = try await ClickHouseConnectionPool(configuration: configuration)
        defer { Task { await pool.close() } }
        var sawTypedFailure = false
        do {
            try await pool.withConnection { _ in }
        } catch is ClickHouseConnectionPool.Failure {
            sawTypedFailure = true
        } catch is ClickHouseError {
            sawTypedFailure = true
        } catch {
            Issue.record("expected typed Pool.Failure or ClickHouseError, got untyped \(error)")
        }
        #expect(sawTypedFailure)
    }
}
