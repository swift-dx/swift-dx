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

// Array(Tuple(..., Bool)) is the stored form of a Nested column with a Bool
// sub-column - a common shape. Its element types are resolved through the
// same Map/Tuple element-type parser that Map values use, so the Bool case
// that Map needs is exactly the case this path needs too. This pins the
// arrayOfTuple-with-Bool decode end to end, alongside the Map(Bool) case.
@Suite("Array(Tuple) with a Bool element decodes")
struct ArrayTupleBoolTests {

    private struct Row: Codable, Sendable {
        let a: ClickHouseArrayOfTuple
    }

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    @Test("Array(Tuple(Bool, Int32)) decodes its Bool first-position element")
    func decodesArrayOfTupleWithBool() throws {
        // One row holding one tuple (true, 42): cumulative offset 1, then the
        // flattened Bool first-position column (0x01), then the Int32 second
        // column (42 little-endian).
        let body: [UInt8] = Self.uint64LE(1) + [0x01] + [42, 0, 0, 0]
        let block = ClickHouseBlock(
            rowCount: 1, columnCount: 1,
            columnNames: ["a"],
            columnTypes: ["Array(Tuple(Bool, Int32))"],
            bodyStart: 0, bodyLength: body.count
        )
        let decoded = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: decoded, rowCount: 1)

        #expect(rows[0].a.firstElement == .bool)
        #expect(rows[0].a.secondElement == .int32)
        #expect(rows[0].a.firstValues == [[1]])
        #expect(rows[0].a.secondValues == [[42, 0, 0, 0]])
    }
}
