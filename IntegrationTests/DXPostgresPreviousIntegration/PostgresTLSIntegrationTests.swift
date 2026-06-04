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

import DXPostgresPrevious
import Testing

@Suite struct PostgresTLSIntegrationTests {

    @Test(.enabled(if: PostgresIntegration.isTLSEnabled)) func connectsOverTLSAndConfirmsEncryption() async throws {
        try await Postgres.withClient(PostgresIntegration.makeTLSConfiguration()) { client in
            let row = try await client.query("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()").rows[0]
            #expect(try row.decode(Bool.self, named: "ssl") == true)
        }
    }

    @Test(.enabled(if: PostgresIntegration.isTLSEnabled)) func runsQueriesOverTLS() async throws {
        try await Postgres.withClient(PostgresIntegration.makeTLSConfiguration()) { client in
            let row = try await client.query("SELECT $1::int * 3 AS tripled", binding: [14]).rows[0]
            #expect(try row.decode(Int.self, named: "tripled") == 42)
        }
    }

    @Test(.enabled(if: PostgresIntegration.isEnabled)) func requiringTLSAgainstAPlaintextServerFails() async throws {
        await #expect(throws: PostgresError.self) {
            try await Postgres.withClient(PostgresIntegration.makeTLSRequiredAgainstPlaintextConfiguration()) { client in
                _ = try await client.query("SELECT 1")
            }
        }
    }
}
