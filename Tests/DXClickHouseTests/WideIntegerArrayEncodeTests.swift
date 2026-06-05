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

// Array(Int128) / Array(UInt128) decode natively into [ClickHouseInt128] /
// [ClickHouseUInt128], but inserting them was impossible: the raw-bytes
// FixedString shape produced the wrong column type. First-class 128-bit
// element types make these wide-integer arrays insert symmetrically.
@Suite("[ClickHouseInt128/UInt128] arrays insert symmetrically with how they select")
struct WideIntegerArrayEncodeTests {

    private struct Int128Row: Codable, Sendable, Equatable { let values: [ClickHouseInt128] }
    private struct UInt128Row: Codable, Sendable, Equatable { let values: [ClickHouseUInt128] }

    @Test("a [ClickHouseInt128] field round-trips, including a negative")
    func int128RoundTrips() throws {
        let original = [Int128Row(values: [ClickHouseInt128(Int128(100)), ClickHouseInt128(Int128(-5))])]
        let columns = try ClickHouseRowEncoder().encode(original)
        #expect(columns[0].column.typeName == "Array(Int128)")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Int128Row.self, columns: columns, rowCount: 1)
        #expect(decoded == original)
    }

    @Test("an empty [ClickHouseInt128] encodes as an empty Array(Int128)")
    func int128Empty() throws {
        let original = [Int128Row(values: [])]
        let columns = try ClickHouseRowEncoder().encode(original)
        #expect(columns[0].column.typeName == "Array(Int128)")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Int128Row.self, columns: columns, rowCount: 1)
        #expect(decoded == original)
    }

    @Test("a [ClickHouseUInt128] field round-trips")
    func uint128RoundTrips() throws {
        let original = [UInt128Row(values: [ClickHouseUInt128(UInt128(1)), ClickHouseUInt128(UInt128(0xFFFF_FFFF_FFFF_FFFF))])]
        let columns = try ClickHouseRowEncoder().encode(original)
        #expect(columns[0].column.typeName == "Array(UInt128)")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: UInt128Row.self, columns: columns, rowCount: 1)
        #expect(decoded == original)
    }
}
