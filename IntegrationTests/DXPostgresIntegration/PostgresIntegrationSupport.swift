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

import DXPostgres
import Foundation
import NIOCore
import NIOPosix

// Shared helpers for the live-server integration suites. Every suite is gated on
// POSTGRES_INTEGRATION_HOST so the tests skip automatically when no server is
// reachable. Run with:
//
//     POSTGRES_INTEGRATION_HOST=localhost \
//     POSTGRES_INTEGRATION_USER=dxpostgres \
//     POSTGRES_INTEGRATION_PASSWORD=dxpostgres \
//     POSTGRES_INTEGRATION_DB=dxpostgres \
//     swift test --filter DXPostgresIntegration
//
// Optional env vars: POSTGRES_INTEGRATION_PORT (default 5432).
enum PostgresIntegration {

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["POSTGRES_INTEGRATION_HOST"] != nil
    }

    static var host: String {
        environment("POSTGRES_INTEGRATION_HOST", fallback: "localhost")
    }

    static var port: Int {
        Int(environment("POSTGRES_INTEGRATION_PORT", fallback: "5432")) ?? 5432
    }

    static var username: String {
        environment("POSTGRES_INTEGRATION_USER", fallback: "dxpostgres")
    }

    static var password: String {
        environment("POSTGRES_INTEGRATION_PASSWORD", fallback: "dxpostgres")
    }

    static var database: String {
        environment("POSTGRES_INTEGRATION_DB", fallback: "dxpostgres")
    }

    static func makeConfiguration(maxConnections: Int = 4, requestTimeout: TimeAmount = .seconds(30), resilience: PostgresResilience = PostgresResilience()) -> PostgresConfiguration {
        PostgresConfiguration(
            endpoint: PostgresEndpoint(host: host, port: port),
            credentials: .password(username: username, password: password),
            database: PostgresDatabaseName(database),
            eventLoopGroup: MultiThreadedEventLoopGroup.singleton,
            requestTimeout: requestTimeout,
            maxConnections: maxConnections,
            maxIdleConnections: maxConnections,
            resilience: resilience
        )
    }

    // A second server configured for cleartext password authentication, gated on
    // its own env var so it is skipped unless one is running.
    static var cleartextPort: Int {
        Int(environment("POSTGRES_INTEGRATION_CLEARTEXT_PORT", fallback: "0")) ?? 0
    }

    static var isCleartextEnabled: Bool {
        isEnabled && cleartextPort > 0
    }

    static func makeCleartextConfiguration() -> PostgresConfiguration {
        PostgresConfiguration(
            endpoint: PostgresEndpoint(host: host, port: cleartextPort),
            credentials: .password(username: username, password: password),
            database: PostgresDatabaseName(database),
            eventLoopGroup: MultiThreadedEventLoopGroup.singleton,
            maxConnections: 2,
            maxIdleConnections: 2
        )
    }

    // A PostGIS-enabled server (the postgis/postgis image), gated on its own env
    // var. PostGIS is a PostgreSQL extension that YugabyteDB does not provide, so
    // the geometry suite only runs against this server.
    static var postGISPort: Int {
        Int(environment("POSTGRES_INTEGRATION_POSTGIS_PORT", fallback: "0")) ?? 0
    }

    static var isPostGISEnabled: Bool {
        isEnabled && postGISPort > 0
    }

    static func makePostGISConfiguration() -> PostgresConfiguration {
        PostgresConfiguration(
            endpoint: PostgresEndpoint(host: host, port: postGISPort),
            credentials: .password(username: username, password: password),
            database: PostgresDatabaseName(database),
            eventLoopGroup: MultiThreadedEventLoopGroup.singleton,
            maxConnections: 2,
            maxIdleConnections: 2
        )
    }

    static var tlsPort: Int {
        Int(environment("POSTGRES_INTEGRATION_TLS_PORT", fallback: "0")) ?? 0
    }

    static var tlsCertificatePath: String {
        environment("POSTGRES_INTEGRATION_TLS_CERT", fallback: "")
    }

    static var isTLSEnabled: Bool {
        isEnabled && tlsPort > 0 && !tlsCertificatePath.isEmpty
    }

    static func makeTLSConfiguration() -> PostgresConfiguration {
        PostgresConfiguration(
            endpoint: PostgresEndpoint(host: host, port: tlsPort),
            credentials: .password(username: username, password: password),
            database: PostgresDatabaseName(database),
            transportSecurity: .tls(PostgresTLSConfiguration(serverName: .explicit("localhost"), trustRoots: .certificateFile(path: tlsCertificatePath))),
            maxConnections: 2,
            maxIdleConnections: 2
        )
    }

    static func makeTLSRequiredAgainstPlaintextConfiguration() -> PostgresConfiguration {
        PostgresConfiguration(
            endpoint: PostgresEndpoint(host: host, port: port),
            credentials: .password(username: username, password: password),
            database: PostgresDatabaseName(database),
            transportSecurity: .tls(PostgresTLSConfiguration()),
            maxConnections: 1,
            maxIdleConnections: 1
        )
    }

    private static func environment(_ key: String, fallback: String) -> String {
        ProcessInfo.processInfo.environment[key] ?? fallback
    }
}
