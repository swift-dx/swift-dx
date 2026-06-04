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
import Foundation
import Testing

@Suite(.enabled(if: PostgresIntegration.isEnabled)) struct PostgresPreparedStatementIntegrationTests {

    @Test func repeatedParameterizedQueryStaysCorrectAcrossCacheHits() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration(maxConnections: 1)) { postgres in
            for value in 0..<50 {
                let row = try await postgres.query("SELECT $1::int * 2 AS doubled", binding: [value]).rows[0]
                #expect(try row.decode(Int.self, named: "doubled") == value * 2)
            }
        }
    }

    @Test func parseErrorDoesNotPoisonLaterQueries() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration(maxConnections: 1)) { postgres in
            await #expect(throws: PostgresError.self) {
                _ = try await postgres.query("SELECT $1::int FROM", binding: [1])
            }
            await #expect(throws: PostgresError.self) {
                _ = try await postgres.query("SELECT $1::int FROM", binding: [1])
            }
            let row = try await postgres.query("SELECT $1::int AS ok", binding: [7]).rows[0]
            #expect(try row.decode(Int.self, named: "ok") == 7)
        }
    }
}
