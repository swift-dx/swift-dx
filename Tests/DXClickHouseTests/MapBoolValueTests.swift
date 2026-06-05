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

// Bool is a valid Map key/value element and a valid Array(Tuple) element in
// ClickHouse, and Array(Bool) already decodes. But the Map/Tuple element-type
// parser (shared by Map and Array(Tuple) decoding) omitted Bool, so a
// Map(String, Bool) column - or an Array(Tuple(..., Bool)) - was rejected with
// "unsupported Map element type Bool" even though the column builder already
// knows how to materialise a Bool element. The two element-type parsers must
// accept the same scalar set.
@Suite("Map and Array(Tuple) accept a Bool element, matching Array(Bool)")
struct MapBoolValueTests {

    private struct Row: Codable, Sendable {
        let m: ClickHouseMap
    }

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    @Test("a Map(String, Bool) column decodes its Bool value instead of being rejected")
    func decodesMapWithBoolValue() throws {
        // One row, one entry {"k": true}: cumulative offset 1, then the key
        // String column ("k"), then the Bool value column (0x01 = true).
        let body: [UInt8] = Self.uint64LE(1) + [0x01, 0x6b] + [0x01]
        let block = ClickHouseBlock(
            rowCount: 1, columnCount: 1,
            columnNames: ["m"],
            columnTypes: ["Map(String, Bool)"],
            bodyStart: 0, bodyLength: body.count
        )
        let decoded = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: decoded, rowCount: 1)

        #expect(rows[0].m.valueElement == .bool)
        #expect(rows[0].m.keys == [Array("k".utf8)])
        #expect(rows[0].m.values == [[1]])
    }
}
