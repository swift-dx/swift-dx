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

// An Array(T) column maps most naturally onto a native Swift array field
// ([String], [Int64], [Double], [Bool], ...). That used to fail: the
// columnar decoder routed a native array target through an unkeyed
// container it did not implement, so callers were forced onto the
// raw-bytes ClickHouseArray escape hatch. A native array of a supported
// element type must now decode directly, and a Swift type that does not
// match the column's element type is rejected.
@Suite("an Array column decodes into a native Swift array")
struct NativeArrayDecodeTests {

    private struct Row: Decodable {
        let tags: [String]
        let counts: [Int64]
        let codes: [UInt32]
        let ratios: [Double]
        let flags: [Bool]
    }

    private static func uint32Bytes(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    @Test("each supported element type decodes into its Swift array")
    func decodesEachElementType() throws {
        let codeElements = [Self.uint32Bytes(1), Self.uint32Bytes(2), Self.uint32Bytes(3)]
        let columns = [
            ClickHouseNamedColumn(name: "tags", column: .array([[Array("a".utf8), Array("bee".utf8)]], element: .string)),
            ClickHouseNamedColumn(name: "counts", column: .array([ClickHouseArray.int64s([-5, 9_000_000_000]).elements], element: .int64)),
            ClickHouseNamedColumn(name: "codes", column: .array([codeElements], element: .uint32)),
            ClickHouseNamedColumn(name: "ratios", column: .array([ClickHouseArray.float64s([1.5, -2.25]).elements], element: .float64)),
            ClickHouseNamedColumn(name: "flags", column: .array([ClickHouseArray.bools([true, false, true]).elements], element: .bool)),
        ]
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 1)
        #expect(rows[0].tags == ["a", "bee"])
        #expect(rows[0].counts == [-5, 9_000_000_000])
        #expect(rows[0].codes == [1, 2, 3])
        #expect(rows[0].ratios == [1.5, -2.25])
        #expect(rows[0].flags == [true, false, true])
    }

    @Test("an empty array decodes to an empty Swift array")
    func emptyArray() throws {
        struct Single: Decodable { let tags: [String] }
        let columns = [ClickHouseNamedColumn(name: "tags", column: .array([[]], element: .string))]
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Single.self, columns: columns, rowCount: 1)
        #expect(rows[0].tags == [])
    }

    @Test("a Swift array whose element type does not match the column is rejected")
    func mismatchedElementThrows() {
        struct Single: Decodable { let tags: [Int64] }
        let columns = [ClickHouseNamedColumn(name: "tags", column: .array([[Array("a".utf8)]], element: .string))]
        #expect(throws: (any Error).self) {
            _ = try ClickHouseCodableDecoder.decodeRows(type: Single.self, columns: columns, rowCount: 1)
        }
    }
}
