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

// Confirms the metrics counters reflect real activity end to end: completed
// queries, a physical connection open, and a server-side failure all show up in
// the snapshot. Runs against both PostgreSQL and YugabyteDB.
@Suite(.enabled(if: PostgresIntegration.isEnabled)) struct PostgresObservabilityIntegrationTests {

    @Test func countsQueriesConnectionsAndErrors() async throws {
        let client = PostgresClient(configuration: PostgresIntegration.makeConfiguration(maxConnections: 2))
        _ = try await client.query("SELECT 1")
        _ = try await client.query("SELECT $1::int", binding: [7])

        await #expect(throws: PostgresError.self) {
            _ = try await client.query("SELECT * FROM a_table_that_does_not_exist_dx")
        }

        let metrics = client.metrics()
        #expect(metrics.queriesTotal >= 3)
        #expect(metrics.queryErrorsTotal >= 1)
        #expect(metrics.connectionsOpenedTotal >= 1)
        #expect(metrics.meanQueryDurationNanos > 0)

        let pool = await client.poolStats()
        #expect(pool.maxConnections == 2)
        #expect(pool.totalConnections >= 1)

        await client.shutdown()
    }
}
