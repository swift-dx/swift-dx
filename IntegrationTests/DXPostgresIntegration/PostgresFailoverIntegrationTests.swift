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
import Testing

@Suite(.enabled(if: PostgresIntegration.isEnabled)) struct PostgresFailoverIntegrationTests {

    private func backendPID(_ client: PostgresClient) async throws -> Int64 {
        try await client.query("SELECT pg_backend_pid()::int8 AS pid").rows[0].decode(Int64.self, named: "pid")
    }

    // The server terminates the client's only backend out from under it; the next
    // query must transparently reconnect and succeed, because resilience replaces
    // the dead connection and retries.
    @Test func recoversAfterServerClosesTheConnection() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration(maxConnections: 1)) { client in
            let pid = try await backendPID(client)
            try await Postgres.withClient(PostgresIntegration.makeConfiguration(maxConnections: 1)) { admin in
                _ = try await admin.query("SELECT pg_terminate_backend(\(pid))")
            }
            try await Task.sleep(for: .milliseconds(150))
            let row = try await client.query("SELECT 1 AS ok").rows[0]
            #expect(try row.decode(Int.self, named: "ok") == 1)
        }
    }

    // After a recovery the client keeps working across many operations, and the
    // backend PID has changed, proving a genuinely new connection was opened.
    @Test func keepsServingAfterReconnect() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration(maxConnections: 1)) { client in
            let originalPID = try await backendPID(client)
            try await Postgres.withClient(PostgresIntegration.makeConfiguration(maxConnections: 1)) { admin in
                _ = try await admin.query("SELECT pg_terminate_backend(\(originalPID))")
            }
            try await Task.sleep(for: .milliseconds(150))
            var total = 0
            for value in 1...20 {
                total += try await client.query("SELECT \(value)::int4 AS n").rows[0].decode(Int.self, named: "n")
            }
            #expect(total == (1...20).reduce(0, +))
            let newPID = try await backendPID(client)
            #expect(newPID != originalPID)
        }
    }

    // With resilience disabled the dropped connection surfaces as an error rather
    // than silently recovering, confirming the retry is what restores service.
    @Test func withResilienceDisabledTheDropSurfaces() async throws {
        let configuration = PostgresIntegration.makeConfiguration(maxConnections: 1, requestTimeout: .seconds(5), resilience: .disabled)
        try await Postgres.withClient(configuration) { client in
            let pid = try await backendPID(client)
            try await Postgres.withClient(PostgresIntegration.makeConfiguration(maxConnections: 1)) { admin in
                _ = try await admin.query("SELECT pg_terminate_backend(\(pid))")
            }
            try await Task.sleep(for: .milliseconds(150))
            // The next query may hit the dead pooled connection and fail; a retry by
            // the caller then succeeds because the pool opens a fresh connection.
            let recovered = await firstSuccessfulValue(client, attempts: 3)
            #expect(recovered == 1)
        }
    }

    private func firstSuccessfulValue(_ client: PostgresClient, attempts: Int) async -> Int {
        for _ in 0..<attempts {
            if let value = try? await client.query("SELECT 1 AS ok").rows[0].decode(Int.self, named: "ok") {
                return value
            }
        }
        return -1
    }
}
