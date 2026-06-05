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

@testable import DXClickHouse
import Testing

// Observability schemas lean on Map(String, UInt64) / Map(String, Int64) /
// Map(String, Float64) - ProfileEvents, per-label counters, ratios. Those
// map most naturally onto [String: UInt64] / [String: Int64] /
// [String: Double] fields. Only [String: String] worked before; the numeric
// value variants were rejected, forcing the raw-bytes ClickHouseMap escape
// hatch. Each now round-trips, keyed on the static dictionary type so an
// empty map keeps its declared value element type.
@Suite("Map(String, numeric) round-trips through a numeric-valued Swift dictionary")
struct NativeNumericMapCodableTests {

    private struct Row: Codable, Equatable {
        let labels: [String: String]
        let counts: [String: Int64]
        let totals: [String: UInt64]
        let ratios: [String: Double]
    }

    @Test("each value type round-trips through encode then decode")
    func roundTripsEachValueType() throws {
        let original = Row(
            labels: ["env": "prod"],
            counts: ["reads": -3, "writes": 9_000_000_000],
            totals: ["bytes": 18_000_000_000, "rows": 0],
            ratios: ["hit": 0.875, "miss": -1.5]
        )
        let columns = try ClickHouseRowEncoder().encode([original])
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 1)
        #expect(decoded == [original])
    }

    @Test("an empty numeric map keeps its value element type")
    func emptyNumericMap() throws {
        struct Single: Codable, Equatable { let totals: [String: UInt64] }
        let original = Single(totals: [:])
        let columns = try ClickHouseRowEncoder().encode([original])
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Single.self, columns: columns, rowCount: 1)
        #expect(decoded == [original])
    }

    @Test("a UInt64-valued dictionary over a String-valued map is rejected")
    func mismatchedValueTypeThrows() {
        struct Single: Codable, Equatable { let totals: [String: UInt64] }
        let column = ClickHouseNamedColumn(
            name: "totals",
            column: .map(keys: [[Array("k".utf8)]], values: [[Array("v".utf8)]], keyElement: .string, valueElement: .string)
        )
        #expect(throws: (any Error).self) {
            _ = try ClickHouseCodableDecoder.decodeRows(type: Single.self, columns: [column], rowCount: 1)
        }
    }
}
