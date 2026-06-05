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
import Testing

// The native [String: V] map decode and encode covered only String, Int64,
// UInt64, and Double values, while the array element paths cover every
// fixed-width scalar. That left Map(String, Int32) and the other narrow
// numeric and Bool value maps (common for compact per-label counters and
// flag maps) failing, forcing the raw-bytes ClickHouseMap escape hatch. This
// brings the map value coverage to parity with the array element coverage.
@Suite("Map(String, narrow numeric / Bool) round-trips through a Swift dictionary")
struct NativeNarrowNumericMapTests {

    private struct Row: Codable, Equatable {
        let i8: [String: Int8]
        let i16: [String: Int16]
        let i32: [String: Int32]
        let u8: [String: UInt8]
        let u16: [String: UInt16]
        let u32: [String: UInt32]
        let f32: [String: Float]
        let flags: [String: Bool]
    }

    @Test("each narrow value type round-trips through encode then decode")
    func roundTrips() throws {
        let original = Row(
            i8: ["a": -5, "b": 120],
            i16: ["a": -300, "b": 30_000],
            i32: ["a": -70_000, "b": 2_000_000_000],
            u8: ["a": 0, "b": 250],
            u16: ["a": 65_000],
            u32: ["a": 4_000_000_000],
            f32: ["a": 1.5, "b": -2.25],
            flags: ["on": true, "off": false]
        )
        let columns = try ClickHouseRowEncoder().encode([original])
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 1)
        #expect(decoded == [original])
    }

    @Test("an empty narrow numeric map keeps its value element type")
    func emptyMap() throws {
        struct Single: Codable, Equatable { let counts: [String: Int32] }
        let original = Single(counts: [:])
        let columns = try ClickHouseRowEncoder().encode([original])
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Single.self, columns: columns, rowCount: 1)
        #expect(decoded == [original])
    }
}
