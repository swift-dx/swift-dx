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

// Single-round-trip latency on the scalar API. PRODUCTION-3WAY-BENCH.md
// does not capture this directly; localhost loopback SELECT 1 sits at
// single-digit milliseconds with a single connection. The harness uses
// a 5 ms baseline (so the threshold is 6 ms median).
@Suite(
    "DXClickHouse scalar performance",
    .enabled(if: ClickHousePerformanceHarness.isEnabled)
)
struct ScalarPerformanceTests {

    @Test("scalar UInt64 SELECT round-trip median stays under baseline * 1.2")
    func scalarRoundTrip() async throws {
        let client = try await ClickHousePerformanceHarness.makeClient()
        try await ClickHousePerformanceHarness.measureRepeated(
            mode: "scalar_select_round_trip",
            iterations: 200,
            warmupIterations: 5,
            baselineMedianMs: ClickHousePerformanceBaselines.scaled(
                ClickHousePerformanceBaselines.scalarRoundTripMs
            )
        ) {
            let value: UInt64 = try await client.scalar("SELECT toUInt64(42)", as: UInt64.self)
            #expect(value == 42)
        }
        await client.close()
    }

    @Test("scalar String SELECT round-trip median stays under baseline * 1.2")
    func scalarStringRoundTrip() async throws {
        let client = try await ClickHousePerformanceHarness.makeClient()
        try await ClickHousePerformanceHarness.measureRepeated(
            mode: "scalar_select_string_round_trip",
            iterations: 200,
            warmupIterations: 5,
            baselineMedianMs: ClickHousePerformanceBaselines.scaled(
                ClickHousePerformanceBaselines.scalarRoundTripMs
            )
        ) {
            let value: String = try await client.scalar("SELECT 'hello'", as: String.self)
            #expect(value == "hello")
        }
        await client.close()
    }
}
