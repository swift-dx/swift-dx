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
import Foundation
import Testing

// Array(Nullable(FixedString(N))) carries its width N on the column element,
// so it uses a dedicated path (the closure-based wrappers cannot capture N).
// Decode reads N from the column; encode infers N from the present elements of
// the row, sharing the non-nullable FixedString array's first-row width
// requirement.
@Suite("Array(Nullable(FixedString)) round-trips and infers its width")
struct ArrayOfNullableFixedStringTests {

    private struct Row: Codable, Sendable, Equatable { let v: [ClickHouseFixedString?] }

    private static func fs(_ s: String) -> ClickHouseFixedString {
        ClickHouseFixedString(bytes: Array(s.utf8), length: 4)
    }

    @Test("a [ClickHouseFixedString?] batch round-trips with interspersed NULLs")
    func roundTrips() throws {
        let rows = [Row(v: [Self.fs("aaaa"), nil, Self.fs("cccc")]), Row(v: [nil, Self.fs("bbbb")])]
        let columns = try ClickHouseRowEncoder().encode(rows)
        #expect(columns[0].column.typeName == "Array(Nullable(FixedString(4)))")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: rows.count)
        #expect(decoded == rows)
    }

    @Test("a non-UTF-8 FixedString element survives the round trip byte-for-byte")
    func binarySafe() throws {
        let raw = ClickHouseFixedString(bytes: [0xFF, 0x00, 0xFE, 0x80], length: 4)
        let rows = [Row(v: [raw, nil])]
        let columns = try ClickHouseRowEncoder().encode(rows)
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 1)
        #expect(decoded == rows)
    }

    @Test("a row with no present element cannot establish the FixedString width")
    func allNilRowRejected() {
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseRowEncoder().encode([Row(v: [nil, nil])])
        }
    }
}
