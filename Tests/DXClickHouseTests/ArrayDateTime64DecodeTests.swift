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

// Array(DateTime64(P)) carries sub-second timestamp sequences, common in
// high-frequency event data. Each element is an 8-byte signed tick count of
// 10^-P-second units. Unlike the fixed-width temporal element types, the
// element carries its precision. It decodes into [Date] (ticks scaled by the
// precision) and, preserving the raw ticks and precision, into
// [ClickHouseDateTime64]. The decoder previously rejected the element type,
// failing the whole select.
@Suite("DXClickHouse Array(DateTime64) decode")
struct ArrayDateTime64DecodeTests {

    struct DateRow: Codable, Sendable, Equatable { let stamps: [Date] }
    struct TicksRow: Codable, Sendable, Equatable { let stamps: [ClickHouseDateTime64] }

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func int64LE(_ value: Int64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    // One row holding two DateTime64(3) ticks: 1.7e9 s exactly, and the same
    // plus half a millisecond.
    private static func body() -> [UInt8] {
        uint64LE(2) + int64LE(1_700_000_000_000) + int64LE(1_700_000_000_500)
    }

    private static func block() -> ClickHouseBlock {
        ClickHouseBlock(
            rowCount: 1, columnCount: 1,
            columnNames: ["stamps"],
            columnTypes: ["Array(DateTime64(3))"],
            bodyStart: 0, bodyLength: Self.body().count
        )
    }

    @Test("Array(DateTime64(3)) decodes into [Date] scaled by the precision")
    func decodesIntoDates() throws {
        let body = Self.body()
        let columns = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: Self.block(), body: raw)
        }
        let rows = try ClickHouseCodableDecoder.decodeRows(type: DateRow.self, columns: columns, rowCount: 1)
        #expect(rows == [DateRow(stamps: [
            Date(timeIntervalSince1970: 1_700_000_000),
            Date(timeIntervalSince1970: 1_700_000_000.5),
        ])])
    }

    @Test("Array(DateTime64(3)) decodes into [ClickHouseDateTime64] preserving ticks")
    func decodesIntoTicks() throws {
        let body = Self.body()
        let columns = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: Self.block(), body: raw)
        }
        let rows = try ClickHouseCodableDecoder.decodeRows(type: TicksRow.self, columns: columns, rowCount: 1)
        #expect(rows == [TicksRow(stamps: [
            ClickHouseDateTime64(ticks: 1_700_000_000_000, precision: 3),
            ClickHouseDateTime64(ticks: 1_700_000_000_500, precision: 3),
        ])])
    }
}
