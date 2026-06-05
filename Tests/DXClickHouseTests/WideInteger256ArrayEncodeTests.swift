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

// Array(Int256) / Array(UInt256) decode natively into [ClickHouseInt256] /
// [ClickHouseUInt256], but inserting them was impossible: the raw-bytes
// FixedString shape produced the wrong column type. First-class 256-bit
// element types complete the wide-integer array insert/select symmetry.
@Suite("[ClickHouseInt256/UInt256] arrays insert symmetrically with how they select")
struct WideInteger256ArrayEncodeTests {

    private struct Int256Row: Codable, Sendable, Equatable { let values: [ClickHouseInt256] }
    private struct UInt256Row: Codable, Sendable, Equatable { let values: [ClickHouseUInt256] }

    @Test("a [ClickHouseInt256] field round-trips, including a negative")
    func int256RoundTrips() throws {
        let original = [Int256Row(values: [
            ClickHouseInt256(limb0: 1, limb1: 2, limb2: 3, limb3: 4),
            ClickHouseInt256(Int64(-1)),
        ])]
        let columns = try ClickHouseRowEncoder().encode(original)
        #expect(columns[0].column.typeName == "Array(Int256)")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Int256Row.self, columns: columns, rowCount: 1)
        #expect(decoded == original)
    }

    @Test("an empty [ClickHouseInt256] encodes as an empty Array(Int256)")
    func int256Empty() throws {
        let original = [Int256Row(values: [])]
        let columns = try ClickHouseRowEncoder().encode(original)
        #expect(columns[0].column.typeName == "Array(Int256)")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Int256Row.self, columns: columns, rowCount: 1)
        #expect(decoded == original)
    }

    @Test("a [ClickHouseUInt256] field round-trips")
    func uint256RoundTrips() throws {
        let original = [UInt256Row(values: [
            ClickHouseUInt256(limb0: 5, limb1: 6, limb2: 7, limb3: 8),
        ])]
        let columns = try ClickHouseRowEncoder().encode(original)
        #expect(columns[0].column.typeName == "Array(UInt256)")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: UInt256Row.self, columns: columns, rowCount: 1)
        #expect(decoded == original)
    }
}
