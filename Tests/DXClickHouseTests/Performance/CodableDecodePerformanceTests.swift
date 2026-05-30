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

// Block-decode throughput for the Codable SELECT path. Mirrors
// PRODUCTION-3WAY-BENCH.md's `select_decode_only` mode but at 100k rows
// per iteration (the bench uses 1M); the per-100k baseline is the
// 1M-row figure / 10 with a safety margin baked in.
@Suite(
    "DXClickHouse Codable block-decode performance",
    .enabled(if: ClickHousePerformanceHarness.isEnabled)
)
struct CodableDecodePerformanceTests {

    struct WideRow: Decodable, Sendable {

        let identifier: UInt64
        let label: String
        let bucket: UInt32
        let payload: String
    }

    @Test("100k-row Codable decode median stays under baseline * 1.2")
    func codableDecode100kRows() async throws {
        let client = try await ClickHousePerformanceHarness.makeClient()
        let sql = """
        SELECT
            toUInt64(number) AS identifier,
            toString(number) AS label,
            toUInt32(number % 1000) AS bucket,
            concat('payload-', toString(number)) AS payload
        FROM numbers(100000)
        """
        try await ClickHousePerformanceHarness.measureRepeated(
            mode: "codable_decode_100k",
            iterations: 3,
            warmupIterations: 1,
            baselineMedianMs: ClickHousePerformanceBaselines.scaled(
                ClickHousePerformanceBaselines.codableDecode100kRowsMs
            )
        ) {
            let rows = try await client.selectAll(sql, as: WideRow.self)
            #expect(rows.count == 100_000)
        }
        await client.close()
    }

    @Test("100k-row Codable streamed decode median stays under baseline * 1.2")
    func codableStreamDecode100kRows() async throws {
        let client = try await ClickHousePerformanceHarness.makeClient()
        let sql = """
        SELECT
            toUInt64(number) AS identifier,
            toString(number) AS label,
            toUInt32(number % 1000) AS bucket,
            concat('payload-', toString(number)) AS payload
        FROM numbers(100000)
        """
        try await ClickHousePerformanceHarness.measureRepeated(
            mode: "codable_stream_decode_100k",
            iterations: 3,
            warmupIterations: 1,
            baselineMedianMs: ClickHousePerformanceBaselines.scaled(
                ClickHousePerformanceBaselines.codableDecode100kRowsMs
            )
        ) {
            var count = 0
            for try await _ in client.select(sql, as: WideRow.self) { count += 1 }
            #expect(count == 100_000)
        }
        await client.close()
    }
}
