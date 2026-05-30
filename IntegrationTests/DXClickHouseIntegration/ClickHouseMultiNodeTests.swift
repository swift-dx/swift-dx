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
import NIOPosix
import Testing

// True multi-node integration tests against a 2-endpoint cluster.
// Skipped automatically unless both `CH_INTEGRATION_HOST` (primary)
// AND `CH_INTEGRATION_HOST_2` (secondary) are set so the suite runs
// only when a real second endpoint is available.
//
// What unit-level multi-host tests cannot prove:
//   - Round-robin actually distributes connections across nodes (vs.
//     pinning to one when both succeed).
//   - The pool's per-endpoint failure cooldown is keyed correctly
//     (a forced failure on one host doesn't poison the other).
//   - `hostname()` SQL projection returns distinct values across
//     enough acquires that we can assert "we hit both nodes".
//
// Each test below issues enough queries that the round-robin must
// have selected each endpoint at least once; failure to do so is a
// real distribution bug.
private func chMultiNodeEnv(_ key: String) -> String? {
    ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 }
}

private let multiNodeConfigured: Bool =
    chMultiNodeEnv("CH_INTEGRATION_HOST") != nil
        && chMultiNodeEnv("CH_INTEGRATION_HOST_2") != nil

@Suite(
    "ClickHouse integration — multi-node cluster",
    .enabled(if: multiNodeConfigured),
    .serialized
)
struct ClickHouseMultiNodeTests {

    private static func env(_ key: String) -> String? { chMultiNodeEnv(key) }

    private static var host1: String { env("CH_INTEGRATION_HOST") ?? "localhost" }
    private static var host2: String { env("CH_INTEGRATION_HOST_2") ?? "localhost" }
    private static var port: Int { Int(env("CH_INTEGRATION_PORT") ?? "9000") ?? 9000 }
    private static var user: String { env("CH_INTEGRATION_USER") ?? "default" }
    private static var password: String { env("CH_INTEGRATION_PASSWORD") ?? "" }
    private static var database: String { env("CH_INTEGRATION_DATABASE") ?? "test" }

    private static func makeClient(maxConnections: Int) -> (ClickHouseClient, EventLoopGroup) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = ClickHouseClient(configuration: .init(
            endpoints: [
                .init(host: host1, port: port),
                .init(host: host2, port: port),
            ],
            database: database,
            user: user,
            password: password,
            maxConnections: maxConnections,
            eventLoopGroup: group
        ))
        return (client, group)
    }

    @Test("a 2-endpoint pool reaches BOTH nodes within a small number of fresh connections")
    func roundRobinHitsBothNodes() async throws {
        // Use 4 max connections and force 4 concurrent queries so the
        // pool opens 4 fresh sockets. Round-robin against 2 endpoints
        // must hit each at least once. Each query asks the server for
        // its hostname; the set of returned hostnames must have at
        // least 2 distinct values (one per node).
        let (client, _) = Self.makeClient(maxConnections: 4)
        defer { Task { await client.shutdown() } }

        // Hold all 4 connections concurrently so the pool actually
        // needs to open 4 distinct sockets. If we ran sequentially,
        // a single hot connection could serve every query and the
        // round-robin wouldn't be exercised.
        async let h1 = client.scalarString("SELECT hostName()")
        async let h2 = client.scalarString("SELECT hostName()")
        async let h3 = client.scalarString("SELECT hostName()")
        async let h4 = client.scalarString("SELECT hostName()")
        let names = try await [h1, h2, h3, h4].compactMap { $0 }
        let distinct = Set(names)
        #expect(distinct.count >= 2, "expected ≥2 distinct hostnames across 4 round-robin acquires; got \(distinct)")
    }

    @Test("a forced bad endpoint does not poison the healthy peer's selection")
    func badEndpointDoesNotPoisonPeer() async throws {
        // Mix a deliberately unreachable endpoint (high port, no listener)
        // with the live primary. The cooldown logic must keep the bad one
        // out of rotation but never block selection of the live one.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: .init(
            endpoints: [
                .init(host: "127.0.0.1", port: 1),  // reserved port; connect refused
                .init(host: Self.host1, port: Self.port),
            ],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            maxConnections: 2,
            eventLoopGroup: group
        ))
        defer { Task { await client.shutdown() } }

        // Eight queries against a 2-endpoint pool with one dead endpoint.
        // Every query must succeed via failover to the live one. If the
        // failover logic poisoned the live endpoint or got stuck on the
        // dead one, queries would error out after the connect timeout.
        for _ in 0..<8 {
            _ = try await client.scalarString("SELECT hostName()")
        }
    }

}
