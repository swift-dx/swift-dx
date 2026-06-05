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

// A ClickHouse Enum8 / Enum16 column is conceptually a named string backed
// by a small integer, and mapping it onto a Swift String field (or a Swift
// String-backed RawRepresentable enum) is the natural, expected pattern.
// Decoding such a column into String used to throw a type mismatch, forcing
// callers onto the raw-value ClickHouseEnum8 escape hatch. It must instead
// yield the selected name; an out-of-mapping value is a corrupt result and
// throws.
@Suite("an Enum column decodes into a Swift String as its selected name")
struct EnumToStringDecodeTests {

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

    private static let mapping = [
        ClickHouseEnumPair(name: "active", value: 1),
        ClickHouseEnumPair(name: "banned", value: 2),
    ]

    @Test("Enum8 decodes to the name string")
    func enum8ToString() throws {
        let column = ClickHouseNamedColumn(name: "status", column: .enum8([1, 2], mapping: Self.mapping))
        let rows = try ClickHouseCodableDecoder.decodeRows(type: StringRow.self, columns: [column], rowCount: 2)
        #expect(rows.map(\.status) == ["active", "banned"])
    }

    @Test("Enum16 decodes to the name string")
    func enum16ToString() throws {
        let column = ClickHouseNamedColumn(name: "status", column: .enum16([2, 1], mapping: Self.mapping))
        let rows = try ClickHouseCodableDecoder.decodeRows(type: StringRow.self, columns: [column], rowCount: 2)
        #expect(rows.map(\.status) == ["banned", "active"])
    }

    @Test("a negative Enum8 value resolves to its name")
    func negativeEnum8() throws {
        let mapping = [ClickHouseEnumPair(name: "absent", value: -1)]
        let column = ClickHouseNamedColumn(name: "status", column: .enum8([-1], mapping: mapping))
        let rows = try ClickHouseCodableDecoder.decodeRows(type: StringRow.self, columns: [column], rowCount: 1)
        #expect(rows[0].status == "absent")
    }

    @Test("an Enum column decodes into a Swift String-backed enum")
    func enumToRawRepresentable() throws {
        let column = ClickHouseNamedColumn(name: "status", column: .enum8([2], mapping: Self.mapping))
        let rows = try ClickHouseCodableDecoder.decodeRows(type: EnumRow.self, columns: [column], rowCount: 1)
        #expect(rows[0].status == .banned)
    }

    @Test("a value outside the mapping throws rather than corrupting the row")
    func unmappedValueThrows() {
        let column = ClickHouseNamedColumn(name: "status", column: .enum8([7], mapping: Self.mapping))
        #expect(throws: (any Error).self) {
            _ = try ClickHouseCodableDecoder.decodeRows(type: StringRow.self, columns: [column], rowCount: 1)
        }
    }
}
