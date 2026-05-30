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

@Suite("ClickHouse connection pool — per-endpoint health in stats")
struct ClickHouseEndpointHealthTests {

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
                clientName: "EndpointHealthTest",
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

    @Test("a fresh pool reports every endpoint as healthy in the same order they were configured")
    func freshPoolReportsAllHealthyInConfiguredOrder() async throws {
        let endpoints: [ClickHouseEndpoint] = [
            .init(host: "h1", port: 9000),
            .init(host: "h2", port: 9000),
            .init(host: "h3", port: 9000)
        ]
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: endpoints,
            connectionFactory: { _ in try Self.makeMockConnection() }
        ))
        let stats = await pool.stats()
        #expect(stats.endpointHealth.count == 3)
        #expect(stats.endpointHealth.map(\.endpoint) == endpoints, "ordering must match configuration")
        #expect(stats.endpointHealth.allSatisfy { $0.status == .healthy })
        #expect(stats.unhealthyEndpointCount == 0)
    }

    @Test("after a failure, the failing endpoint reports .coolingDown while others stay .healthy")
    func failingEndpointShowsCoolingDown() async throws {
        struct InjectedEndpointError: Error {}
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "broken", port: 9000), .init(host: "ok", port: 9000)],
            endpointFailureCooldown: .seconds(60),
            connectionFactory: { endpoint in
                if endpoint.host == "broken" { throw InjectedEndpointError() }
                return try Self.makeMockConnection()
            }
        ))
        _ = try await pool.acquire()
        let stats = await pool.stats()

        let broken = try #require(stats.endpointHealth.first { $0.endpoint.host == "broken" })
        let ok = try #require(stats.endpointHealth.first { $0.endpoint.host == "ok" })
        #expect(broken.status == .coolingDown)
        #expect(ok.status == .healthy)
        #expect(stats.unhealthyEndpointCount == 1)
    }

    @Test("unhealthyEndpointCount equals the count of endpointHealth entries with .coolingDown status")
    func unhealthyCountMatchesArrayShape() async throws {
        struct InjectedEndpointError: Error {}
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [
                .init(host: "ok", port: 9000),
                .init(host: "broken1", port: 9000),
                .init(host: "broken2", port: 9000)
            ],
            endpointFailureCooldown: .seconds(60),
            connectionFactory: { endpoint in
                if endpoint.host.hasPrefix("broken") { throw InjectedEndpointError() }
                return try Self.makeMockConnection()
            }
        ))

        // Force the pool to try multiple endpoints by saturating the pool
        // and letting failover record both broken hosts.
        for _ in 0..<3 {
            _ = try? await pool.acquire()
        }
        let stats = await pool.stats()
        let coolingDownByArray = stats.endpointHealth.filter { $0.status == .coolingDown }.count
        #expect(stats.unhealthyEndpointCount == coolingDownByArray, "the count field must agree with the array")
    }

    @Test("ClickHouseEndpointHealth is Equatable — two snapshots with same endpoint+status compare equal")
    func endpointHealthIsEquatable() {
        let a = ClickHouseEndpointHealth(endpoint: .init(host: "h", port: 9000), status: .healthy)
        let b = ClickHouseEndpointHealth(endpoint: .init(host: "h", port: 9000), status: .healthy)
        let c = ClickHouseEndpointHealth(endpoint: .init(host: "h", port: 9000), status: .coolingDown)
        let d = ClickHouseEndpointHealth(endpoint: .init(host: "other", port: 9000), status: .healthy)
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
    }

    @Test("ClickHouseEndpointHealth.Status has both healthy and coolingDown cases")
    func statusEnumIsExhaustive() {
        #expect(ClickHouseEndpointHealth.Status.allCases.count == 2)
        let names = ClickHouseEndpointHealth.Status.allCases.map(\.rawValue).sorted()
        #expect(names == ["coolingDown", "healthy"])
    }

    @Test("after the cooldown elapses, a previously failing endpoint reports .healthy again")
    func cooldownExpiryRestoresHealth() async throws {
        struct InjectedEndpointError: Error {}
        let nowHolder = AdvanceableClock(initialNanos: 0)
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "broken", port: 9000), .init(host: "ok", port: 9000)],
            endpointFailureCooldown: .seconds(30),
            connectionFactory: { endpoint in
                if endpoint.host == "broken" { throw InjectedEndpointError() }
                return try Self.makeMockConnection()
            },
            nowProvider: { nowHolder.now() }
        ))
        _ = try await pool.acquire()  // records broken endpoint as failing
        let beforeStats = await pool.stats()
        let brokenBefore = try #require(beforeStats.endpointHealth.first { $0.endpoint.host == "broken" })
        #expect(brokenBefore.status == .coolingDown)

        // Advance the clock past the 30-second cooldown
        nowHolder.advance(seconds: 31)
        let afterStats = await pool.stats()
        let brokenAfter = try #require(afterStats.endpointHealth.first { $0.endpoint.host == "broken" })
        #expect(brokenAfter.status == .healthy)
        #expect(afterStats.unhealthyEndpointCount == 0)
    }

}

private final class AdvanceableClock: @unchecked Sendable {

    private let lock = NSLock()
    private var nanos: UInt64

    init(initialNanos: UInt64) {
        self.nanos = initialNanos
    }

    func advance(seconds: Int) {
        lock.lock()
        defer { lock.unlock() }
        nanos += UInt64(seconds) * 1_000_000_000
    }

    func now() -> NIODeadline {
        lock.lock()
        defer { lock.unlock() }
        return NIODeadline.uptimeNanoseconds(nanos)
    }

}
