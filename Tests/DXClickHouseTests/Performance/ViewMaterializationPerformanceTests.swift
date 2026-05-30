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

// String view materialization cost. The wire decoder vends column bytes
// + offsets and lazily materialises Swift `String` only when the caller
// touches a value. This test forces materialisation across every row
// (by reading every `String` field through the Codable decoder) and
// records the wall-clock cost.
//
// PRODUCTION-3WAY-BENCH.md captures the equivalent at 10M rows for
// `select_full_scan_proj` (768.8 ms NIO median). Scaled to 100k rows
// the baseline is ≈ 7.7 ms; we use a 50 ms baseline (×6 headroom) to
// keep the test resilient to small-row noise on shared CI runners.
@Suite(
    "DXClickHouse string view materialisation performance",
    .enabled(if: ClickHousePerformanceHarness.isEnabled)
)
struct ViewMaterializationPerformanceTests {

    struct StringFieldRow: Decodable, Sendable {

        let label: String
    }

    @Test("100k-row String column materialisation median stays under baseline * 1.2")
    func stringColumnMaterialisation100kRows() async throws {
        let client = try await ClickHousePerformanceHarness.makeClient()
        let sql = "SELECT toString(number) AS label FROM numbers(100000)"
        try await ClickHousePerformanceHarness.measureRepeated(
            mode: "view_materialise_strings_100k",
            iterations: 5,
            warmupIterations: 1,
            baselineMedianMs: ClickHousePerformanceBaselines.scaled(
                ClickHousePerformanceBaselines.viewMaterialisation100kRowsMs
            )
        ) {
            let rows = try await client.selectAll(sql, as: StringFieldRow.self)
            #expect(rows.count == 100_000)
            // Touch every value so a lazy view path cannot skip the
            // String materialisation step on either the streaming or
            // the array surface.
            var totalLength = 0
            for row in rows { totalLength &+= row.label.utf8.count }
            #expect(totalLength > 0)
        }
        await client.close()
    }

    @Test("100k-row short-String materialisation median stays under baseline * 1.2")
    func shortStringMaterialisation100kRows() async throws {
        let client = try await ClickHousePerformanceHarness.makeClient()
        // Short, low-cardinality payloads exercise the same dictionary-
        // amortised String vending path as LowCardinality(String) without
        // depending on the LC column-body-width branch (which the raw
        // transport does not yet support for SELECT).
        let sql = "SELECT toString(number % 100) AS label FROM numbers(100000)"
        try await ClickHousePerformanceHarness.measureRepeated(
            mode: "view_materialise_short_strings_100k",
            iterations: 5,
            warmupIterations: 1,
            baselineMedianMs: ClickHousePerformanceBaselines.scaled(
                ClickHousePerformanceBaselines.viewMaterialisation100kRowsMs
            )
        ) {
            let rows = try await client.selectAll(sql, as: StringFieldRow.self)
            #expect(rows.count == 100_000)
            var totalLength = 0
            for row in rows { totalLength &+= row.label.utf8.count }
            #expect(totalLength > 0)
        }
        await client.close()
    }
}
