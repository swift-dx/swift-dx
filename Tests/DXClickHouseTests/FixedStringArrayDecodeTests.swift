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

// Array(FixedString(N)) columns - fixed-width identifier reference lists -
// map onto a Swift [ClickHouseFixedString] field. The plain native-array
// path covers only the variable scalar elements; a FixedString element
// carries a per-column length, so it needs its own decode. Reading is
// unambiguous (the column carries N); inserting still uses
// ClickHouseArray.fixedStrings(_:length:) because an empty Swift array
// cannot convey the fixed width.
@Suite("an Array(FixedString) column decodes into [ClickHouseFixedString]")
struct FixedStringArrayDecodeTests {

    private struct Row: Decodable {
        let refs: [ClickHouseFixedString]
    }

    @Test("each fixed-width element decodes with its full padded bytes")
    func decodesFixedStringElements() throws {
        let first: [UInt8] = Array("abcde".utf8)
        let second: [UInt8] = Array("fg".utf8) + [0, 0, 0]
        let column = ClickHouseNamedColumn(
            name: "refs",
            column: .array([[first, second]], element: .fixedString(length: 5))
        )
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: [column], rowCount: 1)
        #expect(rows[0].refs == [
            ClickHouseFixedString(bytes: first, length: 5),
            ClickHouseFixedString(bytes: second, length: 5),
        ])
    }

    @Test("an empty Array(FixedString) decodes to an empty array")
    func emptyDecodes() throws {
        let column = ClickHouseNamedColumn(name: "refs", column: .array([[]], element: .fixedString(length: 16)))
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: [column], rowCount: 1)
        #expect(rows[0].refs == [])
    }

    @Test("a [ClickHouseFixedString] over a non-FixedString array is rejected")
    func mismatchedElementThrows() {
        let column = ClickHouseNamedColumn(name: "refs", column: .array([[Array("a".utf8)]], element: .string))
        #expect(throws: (any Error).self) {
            _ = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: [column], rowCount: 1)
        }
    }
}
