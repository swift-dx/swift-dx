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

@Suite(.enabled(if: PostgresIntegration.isEnabled)) struct PostgresStreamingIntegrationTests {

    @Test func streamsEveryRowOfALargeResult() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            var sum = 0
            var count = 0
            for try await row in postgres.queryStream("SELECT generate_series(1, 100000) AS n") {
                sum += try row.decode(Int.self, named: "n")
                count += 1
            }
            #expect(count == 100000)
            #expect(sum == 100000 * 100001 / 2)
        }
    }

    @Test func streamsParameterizedQuery() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            var values: [Int] = []
            for try await row in postgres.queryStream("SELECT g AS n FROM generate_series($1::int, $2::int) AS g", binding: [10, 14]) {
                values.append(try row.decode(Int.self, named: "n"))
            }
            #expect(values == [10, 11, 12, 13, 14])
        }
    }

    @Test func breakingEarlyReclaimsAConnection() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration(maxConnections: 2)) { postgres in
            for round in 0..<6 {
                var seen = 0
                for try await _ in postgres.queryStream("SELECT generate_series(1, 100000) AS n") {
                    seen += 1
                    if seen == 3 { break }
                }
                #expect(seen == 3, "round \(round) should have read exactly three rows")
            }
            let afterPing = try await postgres.query("SELECT 1 AS ok")
            #expect(try afterPing.rows[0].decode(Int.self, named: "ok") == 1)
        }
    }

    @Test func streamSurfacesServerError() async throws {
        await #expect(throws: PostgresError.self) {
            try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
                for try await _ in postgres.queryStream("SELECT * FROM a_missing_table_for_streaming") {
                }
            }
        }
    }
}
