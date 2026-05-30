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

// TLS / mTLS connectivity tests against the live cluster's TLS
// endpoint (typically port 9440). Skipped automatically unless the
// minimum env vars are set; the suite is opt-in because TLS verifies
// against a CA file the developer's machine must be able to read:
//
//   CH_TLS_HOST                hostname or IP serving TLS  (required)
//   CH_TLS_CA_PATH             PEM file holding the CA chain  (required)
//   CH_TLS_PORT                TCP port (default 9440)
//   CH_TLS_USER                ClickHouse user
//   CH_TLS_PASSWORD            password (may be empty if cert-only)
//   CH_TLS_DATABASE            default database (default "test")
//   CH_TLS_CLIENT_CERT_PATH    PEM file with the client cert (optional)
//   CH_TLS_CLIENT_KEY_PATH     PEM file with the client key  (optional)
//   CH_TLS_SERVER_NAME         SNI override; useful when the IP differs
//                              from the cert CN
//
// The suite runs a small number of high-signal tests rather than
// re-running the full type matrix over TLS — the wire codec is identical
// once the handshake completes, so an end-to-end round-trip plus a
// trust-chain verification covers the new surface. Client cert/key are
// only attached when both env vars are set, so the same suite covers
// both server-only TLS and full mTLS.
// Top-level configured-check so the @Suite trait can see it at type
// resolution time. ProcessInfo lookups treat empty values as "not set"
// to match the way developers typically clear env vars.
private func chTLSEnv(_ key: String) -> String? {
    ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 }
}

private let chTLSConfigured: Bool =
    chTLSEnv("CH_TLS_HOST") != nil
        && chTLSEnv("CH_TLS_CA_PATH") != nil

@Suite(
    "ClickHouse integration — mTLS",
    .enabled(if: chTLSConfigured),
    .serialized
)
struct ClickHouseTLSConnectivityTests {

    private static func env(_ key: String) -> String? {
        chTLSEnv(key)
    }

    private static var host: String { env("CH_TLS_HOST") ?? "localhost" }
    private static var port: Int { Int(env("CH_TLS_PORT") ?? "9440") ?? 9440 }
    private static var user: String { env("CH_TLS_USER") ?? "default" }
    private static var password: String { env("CH_TLS_PASSWORD") ?? "" }
    private static var database: String { env("CH_TLS_DATABASE") ?? "test" }
    private static var caPath: String { env("CH_TLS_CA_PATH") ?? "" }
    private static var clientCertPath: String { env("CH_TLS_CLIENT_CERT_PATH") ?? "" }
    private static var clientKeyPath: String { env("CH_TLS_CLIENT_KEY_PATH") ?? "" }
    private static var serverName: String? { env("CH_TLS_SERVER_NAME") }

    private static func makeClient() -> (ClickHouseClient, EventLoopGroup) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let mutualTLS: ClickHouseClient.TLSOptions.MutualTLS
        if clientCertPath.isEmpty || clientKeyPath.isEmpty {
            mutualTLS = .none
        } else {
            mutualTLS = .provided(
                certificate: .pemFile(path: clientCertPath),
                privateKey: .pemFile(path: clientKeyPath)
            )
        }
        let resolvedServerName: ClickHouseClient.TLSOptions.ServerNameSelection
        if let serverName = serverName {
            resolvedServerName = .explicit(serverName)
        } else {
            resolvedServerName = .explicit(host)
        }
        let tls = ClickHouseClient.TLSOptions(
            serverName: resolvedServerName,
            trustRoots: .file(path: caPath),
            mutualTLS: mutualTLS
        )
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: host, port: port)],
            database: database,
            user: user,
            password: password,
            eventLoopGroup: group,
            transportSecurity: .tls(tls)
        ))
        return (client, group)
    }

    @Test("mTLS handshake succeeds against the configured TLS endpoint and returns server metadata")
    func mtlsHandshakeReturnsServerInfo() async throws {
        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }
        let info = try await client.serverInfo()
        #expect(!info.name.isEmpty)
        #expect(info.revision >= 54_400)
    }

    @Test("a small INSERT + SELECT round-trip works end-to-end over the TLS channel")
    func mtlsInsertSelectRoundTrip() async throws {
        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }

        let table = "test.tls_round_trip_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        try await client.execute("CREATE TABLE \(table) (id UInt64, name String) ENGINE = Memory")
        defer { Task { try? await client.execute("DROP TABLE \(table)") } }

        let ids: [UInt64] = [1, 2, 3]
        let names: [String] = ["alpha", "beta", "🇳🇿"]
        try await client.insert(into: table, columns: [
            .init(name: "id", values: .uint64(ids)),
            .init(name: "name", values: .string(names))
        ])

        let blocks = try await client.collectSelectColumns("SELECT id, name FROM \(table)")
        let block = try #require(blocks.first { $0.rowCount > 0 })
        let idCol = try #require(block.columns.first { $0.name == "id" })
        let nameCol = try #require(block.columns.first { $0.name == "name" })
        guard case .uint64(let receivedIds) = idCol.values else {
            Issue.record("expected .uint64, got \(idCol.values)"); return
        }
        guard case .string(let receivedNames) = nameCol.values else {
            Issue.record("expected .string, got \(nameCol.values)"); return
        }
        #expect(receivedIds.sorted() == ids.sorted())
        #expect(Set(receivedNames) == Set(names))
    }

    @Test("multiple sequential queries reuse the same TLS connection from the pool")
    func mtlsPoolReuse() async throws {
        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }

        for _ in 0..<10 {
            let value = try await client.scalarInt64("SELECT toInt64(7)")
            #expect(value == 7)
        }
        let stats = await client.poolStats()
        #expect(stats.totalConnectionsOpened <= 2, "pool should reuse the warmed TLS connection")
    }

    @Test(
        "a 2-endpoint TLS pool reaches BOTH nodes via mTLS round-robin",
        .enabled(if: ProcessInfo.processInfo.environment["CH_TLS_HOST_2"] != nil)
    )
    func mtlsRoundRobinHitsBothNodes() async throws {
        // The single-endpoint mTLS tests cover the handshake and codec
        // path. This one specifically exercises the pool's round-robin
        // when BOTH endpoints carry TLS — proving the SNI/cert plumbing
        // is identical for primary and failover endpoints (a single-
        // endpoint test cannot detect a code path that only fires on
        // the second endpoint, e.g., a stale serverHostname capture).
        guard let host2 = Self.env("CH_TLS_HOST_2") else { return }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let mutualTLS: ClickHouseClient.TLSOptions.MutualTLS
        if Self.clientCertPath.isEmpty || Self.clientKeyPath.isEmpty {
            mutualTLS = .none
        } else {
            mutualTLS = .provided(
                certificate: .pemFile(path: Self.clientCertPath),
                privateKey: .pemFile(path: Self.clientKeyPath)
            )
        }
        let resolvedServerName: ClickHouseClient.TLSOptions.ServerNameSelection
        if let serverName = Self.serverName {
            resolvedServerName = .explicit(serverName)
        } else {
            resolvedServerName = .explicit(Self.host)
        }
        let tls = ClickHouseClient.TLSOptions(
            serverName: resolvedServerName,
            trustRoots: .file(path: Self.caPath),
            mutualTLS: mutualTLS
        )
        let client = ClickHouseClient(configuration: .init(
            endpoints: [
                .init(host: Self.host, port: Self.port),
                .init(host: host2, port: Self.port),
            ],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            maxConnections: 4,
            eventLoopGroup: group,
            transportSecurity: .tls(tls)
        ))
        defer { Task { await client.shutdown() } }

        // Drive 4 concurrent SELECT hostName() so the pool actually
        // opens 4 fresh TLS sockets distributed across both endpoints.
        async let h1 = client.scalarString("SELECT hostName()")
        async let h2 = client.scalarString("SELECT hostName()")
        async let h3 = client.scalarString("SELECT hostName()")
        async let h4 = client.scalarString("SELECT hostName()")
        let names = try await [h1, h2, h3, h4].compactMap { $0 }
        let distinct = Set(names)
        #expect(distinct.count >= 2, "expected ≥2 distinct hostnames across 4 mTLS round-robin acquires; got \(distinct)")
    }

}
