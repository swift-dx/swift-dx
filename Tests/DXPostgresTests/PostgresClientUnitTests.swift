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

import Testing

@testable import DXPostgres

// These exercise client surface that needs no server: a client constructed from a
// configuration does not connect until warmed, so the ambient binding, pool
// statistics, and value descriptions can all be checked offline.
@Suite struct PostgresClientUnitTests {

    private func makeClient() -> PostgresClient {
        PostgresClient(configuration: PostgresConfiguration(
            endpoint: PostgresEndpoint(host: "localhost"),
            credentials: .password(username: "u", password: "p"),
            database: PostgresDatabaseName("db")
        ))
    }

    @Test func currentThrowsWithoutAnAmbientBinding() {
        #expect(throws: PostgresError.self) {
            try Postgres.current()
        }
    }

    @Test func withCurrentBindsAndRestoresTheClient() async throws {
        let client = makeClient()
        let resolved = try await Postgres.withCurrent(client) {
            try Postgres.current()
        }
        #expect(resolved === client)
        await client.shutdown()
    }

    @Test func poolStatsStartEmpty() async {
        let client = makeClient()
        let stats = await client.poolStats()
        #expect(stats.idleConnections == 0)
        #expect(stats.inUseConnections == 0)
        #expect(stats.totalConnections == 0)
        #expect(stats.maxConnections == 16)
        await client.shutdown()
    }

    @Test func descriptionsAreReadable() {
        #expect(PostgresEndpoint(host: "db.internal", port: 5433).description == "db.internal:5433")
        #expect(PostgresDatabaseName("appdb").description == "appdb")
        #expect(PostgresCommandTag(raw: "UPDATE 3").description == "UPDATE 3")
        let serverError = PostgresServerError(severity: "ERROR", sqlState: "42P01", message: "relation does not exist")
        #expect(serverError.description == "ERROR 42P01: relation does not exist")
        #expect(PostgresError.connectionClosed.description.isEmpty == false)
        #expect(PostgresError.unsupportedAuthentication(method: "GSS").description.contains("GSS"))
        #expect(PostgresError.columnIsNull(column: "x").description.contains("NULL"))
    }
}
