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

@testable import DXClickHouse
import Foundation
import NIOCore
import NIOEmbedded
import Testing

@Suite("ClickHouse connection pool — stats snapshot")
struct ClickHouseConnectionPoolStatsTests {

    private static let revision: UInt64 = 54_478

    private static func makeMockConnection() throws -> ClickHouseConnection {
        let channel = EmbeddedChannel()
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        try channel.connect(to: address).wait()
        try channel.pipeline.syncOperations.addHandler(
            MessageToByteHandler(ClickHouseOutboundEncoder(revision: revision))
        )
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(ClickHouseInboundDecoder(revision: revision))
        )
        let inboundHandler = ClickHouseInboundStreamHandler()
        try channel.pipeline.syncOperations.addHandler(inboundHandler)
        let metadata = ClickHouseConnectionMetadata(
            negotiatedRevision: revision,
            clientHello: .init(
                clientName: "StatsTest",
                versionMajor: 1, versionMinor: 0, protocolRevision: revision,
                defaultDatabase: "obs", username: "u", password: ""
            ),
            serverHello: .init(
                serverName: "ClickHouse",
                versionMajor: 24, versionMinor: 8, serverRevision: revision,
                serverTimezone: .value("UTC"), displayName: .value("test-1"), versionPatch: .value(1)
            )
        )
        return ClickHouseConnection(channel: channel, inboundHandler: inboundHandler, metadata: metadata)
    }

    @Test("a fresh pool reports zero idle, active, waiters, and total opened")
    func freshPoolReportsZeroes() async throws {
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h1", port: 9000)],
            connectionFactory: { _ in try Self.makeMockConnection() }
        ))
        let stats = await pool.stats()
        #expect(stats.idleCount == 0)
        #expect(stats.activeCount == 0)
        #expect(stats.waiterCount == 0)
        #expect(stats.totalConnectionsOpened == 0)
        #expect(stats.unhealthyEndpointCount == 0)
        #expect(stats.configuredMaxConnections == 10)
        #expect(stats.configuredMaxIdleConnections == 5)
    }

    @Test("after one acquire, activeCount = 1 and totalConnectionsOpened = 1")
    func afterAcquireStatsReflectActive() async throws {
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h1", port: 9000)],
            connectionFactory: { _ in try Self.makeMockConnection() }
        ))
        _ = try await pool.acquire()
        let stats = await pool.stats()
        #expect(stats.activeCount == 1)
        #expect(stats.idleCount == 0)
        #expect(stats.totalConnectionsOpened == 1)
    }

    @Test("after release, the connection moves from active to idle but totalConnectionsOpened stays")
    func releaseMovesActiveToIdleButTotalOpenedRemains() async throws {
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h1", port: 9000)],
            connectionFactory: { _ in try Self.makeMockConnection() }
        ))
        let connection = try await pool.acquire()
        await pool.release(connection)
        let stats = await pool.stats()
        #expect(stats.activeCount == 0)
        #expect(stats.idleCount == 1)
        #expect(stats.totalConnectionsOpened == 1, "lifetime counter must not decrement on release")
    }

    @Test("re-acquiring an idle connection does not increment totalConnectionsOpened")
    func reuseDoesNotIncrementTotalOpened() async throws {
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h1", port: 9000)],
            connectionFactory: { _ in try Self.makeMockConnection() }
        ))
        let first = try await pool.acquire()
        await pool.release(first)
        _ = try await pool.acquire()  // reuses the idle one
        let stats = await pool.stats()
        #expect(stats.activeCount == 1)
        #expect(stats.idleCount == 0)
        #expect(stats.totalConnectionsOpened == 1, "no new socket was opened")
    }

    @Test("opening multiple distinct connections increments totalConnectionsOpened correctly")
    func multipleDistinctOpensIncrementCounter() async throws {
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h1", port: 9000)],
            maxConnections: 5,
            connectionFactory: { _ in try Self.makeMockConnection() }
        ))
        // Hold three connections concurrently — forces three distinct opens.
        let c1 = try await pool.acquire()
        let c2 = try await pool.acquire()
        let c3 = try await pool.acquire()
        let stats = await pool.stats()
        #expect(stats.activeCount == 3)
        #expect(stats.totalConnectionsOpened == 3)
        await pool.release(c1)
        await pool.release(c2)
        await pool.release(c3)
    }

    @Test("a pending acquire that exceeds maxConnections shows up in waiterCount")
    func waiterCountReflectsBlockedAcquires() async throws {
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h1", port: 9000)],
            maxConnections: 1,
            acquireTimeout: .waitUpTo(.seconds(60)),
            connectionFactory: { _ in try Self.makeMockConnection() }
        ))
        _ = try await pool.acquire()  // saturates the pool

        // Spawn an acquire that will be queued (no release happens here)
        let waiterTask = Task<Void, Error> {
            _ = try await pool.acquire()
        }
        // Give the actor enough time to enqueue the waiter
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 5_000_000)
            let s = await pool.stats()
            if s.waiterCount == 1 { break }
        }
        let stats = await pool.stats()
        #expect(stats.waiterCount == 1)
        #expect(stats.activeCount == 1)

        waiterTask.cancel()
        // Allow cancellation to propagate
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    @Test("the stats type is Equatable — two snapshots with the same fields compare equal")
    func statsAreEquatable() {
        let a = ClickHouseConnectionPoolStats(
            idleCount: 1, activeCount: 2, waiterCount: 0,
            totalConnectionsOpened: 7, unhealthyEndpointCount: 0,
            configuredMaxConnections: 10, configuredMaxIdleConnections: 5
        )
        let b = ClickHouseConnectionPoolStats(
            idleCount: 1, activeCount: 2, waiterCount: 0,
            totalConnectionsOpened: 7, unhealthyEndpointCount: 0,
            configuredMaxConnections: 10, configuredMaxIdleConnections: 5
        )
        let c = ClickHouseConnectionPoolStats(
            idleCount: 1, activeCount: 2, waiterCount: 0,
            totalConnectionsOpened: 8, unhealthyEndpointCount: 0,
            configuredMaxConnections: 10, configuredMaxIdleConnections: 5
        )
        #expect(a == b)
        #expect(a != c)
    }

    @Test("unhealthyEndpointCount counts endpoints currently in failure cooldown")
    func unhealthyEndpointCountReflectsRecentFailures() async throws {
        struct InjectedEndpointError: Error {}
        // Two endpoints — first always fails, second always succeeds.
        let factoryCalls = TestSequenceTracker()
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "broken", port: 9000), .init(host: "ok", port: 9000)],
            endpointFailureCooldown: .seconds(60),
            connectionFactory: { endpoint in
                factoryCalls.append(endpoint.host)
                if endpoint.host == "broken" {
                    throw InjectedEndpointError()
                }
                return try Self.makeMockConnection()
            }
        ))
        _ = try await pool.acquire()  // tries broken, fails, falls over to ok
        let stats = await pool.stats()
        #expect(stats.unhealthyEndpointCount == 1, "broken endpoint should be in cooldown")
        #expect(stats.activeCount == 1)
        #expect(factoryCalls.recorded.contains("broken"))
        #expect(factoryCalls.recorded.contains("ok"))
    }

}

private final class TestSequenceTracker: @unchecked Sendable {

    private let lock = NSLock()
    private var _hosts: [String] = []

    var recorded: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _hosts
    }

    func append(_ host: String) {
        lock.lock()
        defer { lock.unlock() }
        _hosts.append(host)
    }

}
