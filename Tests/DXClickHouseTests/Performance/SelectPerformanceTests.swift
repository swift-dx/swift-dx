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

// Performance coverage for the SELECT hot path. Each test runs the
// query a small number of warmups, then records `iterations` timed runs
// and asserts that the median wall-clock time stays inside
// `baseline * 1.2` (regression margin from PRODUCTION-3WAY-BENCH.md).
//
// Gated on CH_PERF_TESTS=1 + a live ClickHouse (CH_INTEGRATION_HOST).
// Default `swift test` runs skip this suite to keep wall clock low.
@Suite(
    "DXClickHouse SELECT performance",
    .enabled(if: ClickHousePerformanceHarness.isEnabled)
)
struct SelectPerformanceTests {

    struct SmallScalarRow: Decodable, Sendable { let value: UInt64 }
    struct GroupByRow: Decodable, Sendable { let bucket: UInt64; let total: UInt64 }
    struct StringFilterRow: Decodable, Sendable { let value: String }

    @Test("select_orderby_limit median stays under baseline * 1.2")
    func selectOrderByLimit() async throws {
        let client = try await ClickHousePerformanceHarness.makeClient()
        try await ClickHousePerformanceHarness.measureRepeated(
            mode: "select_orderby_limit",
            iterations: 5,
            warmupIterations: 1,
            baselineMedianMs: ClickHousePerformanceBaselines.scaled(
                ClickHousePerformanceBaselines.selectOrderByLimitMs
            )
        ) {
            let rows = try await client.selectAll(
                "SELECT toUInt64(number) AS value FROM numbers(1000000) ORDER BY number DESC LIMIT 1000",
                as: SmallScalarRow.self
            )
            #expect(rows.count == 1_000)
        }
        await client.close()
    }

    @Test("select_groupby median stays under baseline * 1.2")
    func selectGroupBy() async throws {
        let client = try await ClickHousePerformanceHarness.makeClient()
        try await ClickHousePerformanceHarness.measureRepeated(
            mode: "select_groupby",
            iterations: 5,
            warmupIterations: 1,
            baselineMedianMs: ClickHousePerformanceBaselines.scaled(
                ClickHousePerformanceBaselines.selectGroupByMs
            )
        ) {
            let rows = try await client.selectAll(
                "SELECT toUInt64(number % 100) AS bucket, toUInt64(count()) AS total FROM numbers(1000000) GROUP BY bucket",
                as: GroupByRow.self
            )
            #expect(rows.count == 100)
        }
        await client.close()
    }

    @Test("select_where_in median stays under baseline * 1.2")
    func selectWhereIn() async throws {
        let client = try await ClickHousePerformanceHarness.makeClient()
        try await ClickHousePerformanceHarness.measureRepeated(
            mode: "select_where_in",
            iterations: 5,
            warmupIterations: 1,
            baselineMedianMs: ClickHousePerformanceBaselines.scaled(
                ClickHousePerformanceBaselines.selectWhereInMs
            )
        ) {
            let rows = try await client.selectAll(
                "SELECT toUInt64(number) AS value FROM numbers(100000) WHERE number IN (1,7,42,99,1729,65535)",
                as: SmallScalarRow.self
            )
            #expect(rows.count >= 1)
        }
        await client.close()
    }

    @Test("select_string_filter median stays under baseline * 1.2")
    func selectStringFilter() async throws {
        let client = try await ClickHousePerformanceHarness.makeClient()
        try await ClickHousePerformanceHarness.measureRepeated(
            mode: "select_string_filter",
            iterations: 5,
            warmupIterations: 1,
            baselineMedianMs: ClickHousePerformanceBaselines.scaled(
                ClickHousePerformanceBaselines.selectStringFilterMs
            )
        ) {
            let rows = try await client.selectAll(
                "SELECT toString(number) AS value FROM numbers(200000) WHERE toString(number) LIKE '%7%'",
                as: StringFilterRow.self
            )
            #expect(rows.count >= 1)
        }
        await client.close()
    }

    @Test("select_string_aggregation median stays under baseline * 1.2")
    func selectStringAggregation() async throws {
        let client = try await ClickHousePerformanceHarness.makeClient()
        try await ClickHousePerformanceHarness.measureRepeated(
            mode: "select_string_aggregation",
            iterations: 5,
            warmupIterations: 1,
            baselineMedianMs: ClickHousePerformanceBaselines.scaled(
                ClickHousePerformanceBaselines.selectLcAggregationMs
            )
        ) {
            let rows = try await client.selectAll(
                "SELECT toString(number % 10) AS bucket, toUInt64(count()) AS total FROM numbers(100000) GROUP BY bucket",
                as: GroupByStringRow.self
            )
            #expect(rows.count == 10)
        }
        await client.close()
    }

    struct GroupByStringRow: Decodable, Sendable { let bucket: String; let total: UInt64 }
}
