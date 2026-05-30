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

import DXClickHouse
import Foundation
import Testing

// Performance coverage for INSERT throughput on the columnar encoder.
// Two modes are mirrored from PRODUCTION-3WAY-BENCH.md:
//   * ledger_bulk_insert    — one large block (100k rows) per iteration
//   * ledger_stream_insert  — many small blocks (10 rows each) per iter
//
// Each test owns a dedicated MergeTree table scoped to a random suffix
// so concurrent runs do not interfere. The suite truncates between
// iterations so per-iteration cost is the encode + send cost, not the
// growing-table cost.
//
// Gated on CH_PERF_TESTS=1 + CH_INTEGRATION_HOST. Default `swift test`
// runs skip this suite.
@Suite(
    "DXClickHouse INSERT performance",
    .enabled(if: ClickHousePerformanceHarness.isEnabled)
)
struct InsertPerformanceTests {

    struct LedgerRow: Encodable, Sendable {

        let identifier: UInt64
        let kind: String
        let payload: String
    }

    @Test("ledger_bulk_insert median stays under baseline * 1.2")
    func ledgerBulkInsert() async throws {
        let client = try await ClickHousePerformanceHarness.makeClient()
        let table = "test_perf_bulk_\(suffix())"
        try await prepareTable(client: client, table: table)
        defer { Task { await dropTable(client: client, table: table) } }
        let rows = makeBulkRows(count: 100_000)
        try await ClickHousePerformanceHarness.measureRepeated(
            mode: "ledger_bulk_insert",
            iterations: 3,
            warmupIterations: 1,
            baselineMedianMs: ClickHousePerformanceBaselines.scaled(
                ClickHousePerformanceBaselines.ledgerBulkInsertMs
            )
        ) {
            try await truncate(client: client, table: table)
            let summary = try await client.insert(into: table, rows: rows)
            #expect(summary.rowsSent == rows.count)
        }
        await dropTable(client: client, table: table)
        await client.close()
    }

    @Test("ledger_stream_insert median stays under baseline * 1.2")
    func ledgerStreamInsert() async throws {
        let client = try await ClickHousePerformanceHarness.makeClient()
        let table = "test_perf_stream_\(suffix())"
        try await prepareTable(client: client, table: table)
        defer { Task { await dropTable(client: client, table: table) } }
        let batch = makeBulkRows(count: 10)
        let batchesPerIteration = 100
        try await ClickHousePerformanceHarness.measureRepeated(
            mode: "ledger_stream_insert",
            iterations: 3,
            warmupIterations: 1,
            baselineMedianMs: ClickHousePerformanceBaselines.scaled(
                ClickHousePerformanceBaselines.ledgerStreamInsertPer100BatchesMs
            )
        ) {
            try await truncate(client: client, table: table)
            for _ in 0..<batchesPerIteration {
                let summary = try await client.insert(into: table, rows: batch)
                #expect(summary.rowsSent == batch.count)
            }
        }
        await dropTable(client: client, table: table)
        await client.close()
    }

    private func makeBulkRows(count: Int) -> [LedgerRow] {
        (0..<count).map { index in
            LedgerRow(
                identifier: UInt64(index),
                kind: "kind-\(index % 32)",
                payload: "payload-\(index)-\(index * 7 % 9973)"
            )
        }
    }

    private func suffix() -> String {
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return String(raw.prefix(12))
    }

    private func prepareTable(client: ClickHouseClient, table: String) async throws {
        try await client.execute(
            "CREATE TABLE IF NOT EXISTS \(table) (identifier UInt64, kind String, payload String) ENGINE = MergeTree ORDER BY identifier"
        )
        try await client.execute("TRUNCATE TABLE \(table)")
    }

    private func truncate(client: ClickHouseClient, table: String) async throws {
        try await client.execute("TRUNCATE TABLE \(table)")
    }

    private func dropTable(client: ClickHouseClient, table: String) async {
        do {
            try await client.execute("DROP TABLE IF EXISTS \(table)")
        } catch {
            // Cleanup is best-effort; the suffix randomisation ensures
            // a leftover does not collide with the next run.
        }
    }
}
