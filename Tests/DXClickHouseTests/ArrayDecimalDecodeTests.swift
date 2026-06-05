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

// Array(Decimal(P, S)) carries sequences of fixed-point amounts, common in
// financial and analytics schemas. Each element is a signed little-endian
// integer whose byte width is selected by the precision (4/8/16/32 bytes),
// sign-extended across the unused high bytes. The decoder rejected the
// Decimal element type, failing the whole select. These pin decode into
// [ClickHouseDecimal] across two storage widths and a negative value.
@Suite("DXClickHouse Array(Decimal) decode")
struct ArrayDecimalDecodeTests {

    struct Row: Codable, Sendable, Equatable { let amounts: [ClickHouseDecimal] }

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func int32LE(_ value: Int32) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func int64LE(_ value: Int64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func decode(columnType: String, body: [UInt8]) throws -> [Row] {
        let block = ClickHouseBlock(
            rowCount: 1, columnCount: 1,
            columnNames: ["amounts"],
            columnTypes: [columnType],
            bodyStart: 0, bodyLength: body.count
        )
        let columns = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        return try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 1)
    }

    @Test("Array(Decimal(9, 2)) decodes 4-byte values including a negative")
    func decodesDecimal32() throws {
        let body = Self.uint64LE(2) + Self.int32LE(12_345) + Self.int32LE(-678)
        let rows = try Self.decode(columnType: "Array(Decimal(9, 2))", body: body)
        #expect(rows == [Row(amounts: [
            ClickHouseDecimal(unscaled: 12_345, precision: 9, scale: 2),
            ClickHouseDecimal(unscaled: -678, precision: 9, scale: 2),
        ])])
    }

    @Test("Array(Decimal(18, 4)) decodes 8-byte values")
    func decodesDecimal64() throws {
        let body = Self.uint64LE(2) + Self.int64LE(9_000_000_000) + Self.int64LE(-1)
        let rows = try Self.decode(columnType: "Array(Decimal(18, 4))", body: body)
        #expect(rows == [Row(amounts: [
            ClickHouseDecimal(unscaled: 9_000_000_000, precision: 18, scale: 4),
            ClickHouseDecimal(unscaled: -1, precision: 18, scale: 4),
        ])])
    }
}
