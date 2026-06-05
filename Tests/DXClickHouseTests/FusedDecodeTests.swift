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

// decodeFusedRows parses a block body in a single pass directly from the
// received bytes. This builds a block body by hand (the on-wire concatenation
// of column bodies) and checks the fused decode reads it back exactly,
// including binding columns by name regardless of order and surfacing a type
// or name mismatch as a typed error.
@Suite("decodeFusedRows parses a block body in one pass")
struct FusedDecodeTests {

    private struct Row: ClickHouseFusedDecodable, Equatable {
        let id: UInt64; let name: String; let value: Double
        init(id: UInt64, name: String, value: Double) { self.id = id; self.name = name; self.value = value }
        static let clickHouseColumnNames = ["id", "name", "value"]
        static func decodeFused(_ block: ClickHouseRawBlock) throws(ClickHouseError) -> [Row] {
            var rows = [Row](); rows.reserveCapacity(block.count)
            for i in 0..<block.count {
                rows.append(Row(id: block.uint64(0, i), name: block.string(1, i), value: block.double(2, i)))
            }
            return rows
        }
    }

    // Column bodies on the wire are concatenated in block-column order:
    // id (UInt64 little-endian, 8 bytes each), name (UVarInt length + bytes),
    // value (Float64 little-endian, 8 bytes each).
    private static func body(ids: [UInt64], names: [String], values: [Double]) -> [UInt8] {
        var out: [UInt8] = []
        for v in ids { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        for s in names {
            let utf8 = Array(s.utf8)
            out.append(UInt8(utf8.count)) // single-byte UVarInt for short strings
            out.append(contentsOf: utf8)
        }
        for v in values { withUnsafeBytes(of: v.bitPattern.littleEndian) { out.append(contentsOf: $0) } }
        return out
    }

    private static func block(rowCount: Int, names: [String], types: [String]) -> ClickHouseBlock {
        ClickHouseBlock(rowCount: rowCount, columnCount: names.count, columnNames: names, columnTypes: types, bodyStart: 0, bodyLength: 0)
    }

    @Test("decodes UInt64, String, Float64 columns from a hand-built body")
    func decodesBlock() throws {
        let bytes = Self.body(ids: [10, 20], names: ["ab", "c"], values: [1.5, -2.0])
        let blk = Self.block(rowCount: 2, names: ["id", "name", "value"], types: ["UInt64", "String", "Float64"])
        let rows = try bytes.withUnsafeBytes { raw throws(ClickHouseError) in
            try ClickHouseCodableDecoder.decodeFusedRows(type: Row.self, block: blk, body: raw)
        }
        #expect(rows == [Row(id: 10, name: "ab", value: 1.5), Row(id: 20, name: "c", value: -2.0)])
    }

    @Test("binds columns by name regardless of block column order")
    func bindsByName() throws {
        // Block order: name, id, value — different from the field order.
        var out: [UInt8] = []
        for s in ["x", "yz"] { out.append(UInt8(s.utf8.count)); out.append(contentsOf: s.utf8) }
        for v: UInt64 in [7, 8] { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        for v: Double in [3.0, 4.0] { withUnsafeBytes(of: v.bitPattern.littleEndian) { out.append(contentsOf: $0) } }
        let blk = Self.block(rowCount: 2, names: ["name", "id", "value"], types: ["String", "UInt64", "Float64"])
        let rows = try out.withUnsafeBytes { raw throws(ClickHouseError) in
            try ClickHouseCodableDecoder.decodeFusedRows(type: Row.self, block: blk, body: raw)
        }
        #expect(rows == [Row(id: 7, name: "x", value: 3.0), Row(id: 8, name: "yz", value: 4.0)])
    }

    @Test("a missing column throws a typed error")
    func missingColumn() {
        let bytes = Self.body(ids: [1], names: ["a"], values: [1.0])
        let blk = Self.block(rowCount: 1, names: ["id", "other", "value"], types: ["UInt64", "String", "Float64"])
        #expect(throws: ClickHouseError.self) {
            _ = try bytes.withUnsafeBytes { raw throws(ClickHouseError) in
                try ClickHouseCodableDecoder.decodeFusedRows(type: Row.self, block: blk, body: raw)
            }
        }
    }

    @Test("an empty block yields no rows")
    func emptyBlock() throws {
        let blk = Self.block(rowCount: 0, names: ["id", "name", "value"], types: ["UInt64", "String", "Float64"])
        let rows = try [UInt8]().withUnsafeBytes { raw throws(ClickHouseError) in
            try ClickHouseCodableDecoder.decodeFusedRows(type: Row.self, block: blk, body: raw)
        }
        #expect(rows.isEmpty)
    }
}
