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

// LowCardinality(T) is transparent storage: LowCardinality(String) is a
// String column with dictionary-encoded storage, and LowCardinality(
// FixedString(N)) a FixedString column. The recommended way to store
// low-cardinality status / category / id columns. Decoding one used to
// force the raw-value ClickHouseLowCardinality escape hatch; a String field
// or a ClickHouseFixedString field must read straight through the
// dictionary, including a Swift String-backed enum over LowCardinality.
@Suite("a LowCardinality column decodes transparently to its inner Swift type")
struct LowCardinalityTransparentDecodeTests {

    private struct StringRow: Decodable {
        let status: String
    }

    private enum Status: String, Decodable {
        case active
        case banned
    }

    private struct EnumRow: Decodable {
        let status: Status
    }

    private struct FixedRow: Decodable {
        let id: ClickHouseFixedString
    }

    @Test("LowCardinality(String) decodes into a Swift String")
    func lowCardinalityStringToString() throws {
        let column = ClickHouseNamedColumn(
            name: "status",
            column: .lowCardinality([Array("active".utf8), Array("banned".utf8), Array("active".utf8)], inner: .string)
        )
        let rows = try ClickHouseCodableDecoder.decodeRows(type: StringRow.self, columns: [column], rowCount: 3)
        #expect(rows.map(\.status) == ["active", "banned", "active"])
    }

    @Test("LowCardinality(String) decodes into a Swift String-backed enum")
    func lowCardinalityStringToEnum() throws {
        let column = ClickHouseNamedColumn(
            name: "status",
            column: .lowCardinality([Array("banned".utf8)], inner: .string)
        )
        let rows = try ClickHouseCodableDecoder.decodeRows(type: EnumRow.self, columns: [column], rowCount: 1)
        #expect(rows[0].status == .banned)
    }

    @Test("LowCardinality(FixedString(N)) decodes into a ClickHouseFixedString")
    func lowCardinalityFixedStringToFixedString() throws {
        let first = Array("abcde".utf8)
        let second = Array("fg".utf8) + [0, 0, 0]
        let column = ClickHouseNamedColumn(
            name: "id",
            column: .lowCardinality([first, second], inner: .fixedString(length: 5))
        )
        let rows = try ClickHouseCodableDecoder.decodeRows(type: FixedRow.self, columns: [column], rowCount: 2)
        #expect(rows.map(\.id) == [
            ClickHouseFixedString(bytes: first, length: 5),
            ClickHouseFixedString(bytes: second, length: 5),
        ])
    }
}
