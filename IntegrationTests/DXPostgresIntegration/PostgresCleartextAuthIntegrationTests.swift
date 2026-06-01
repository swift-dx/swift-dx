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
import Testing

@Suite(.enabled(if: PostgresIntegration.isCleartextEnabled)) struct PostgresCleartextAuthIntegrationTests {

    @Test func connectsWithCleartextPasswordAuthentication() async throws {
        try await Postgres.withClient(PostgresIntegration.makeCleartextConfiguration()) { client in
            let row = try await client.query("SELECT 1 AS ok").rows[0]
            #expect(try row.decode(Int.self, named: "ok") == 1)
        }
    }
}
