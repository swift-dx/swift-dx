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

// Iter 83 made a non-null Enum column decode into a Swift String. But a
// Nullable(Enum8) column is carried as the generic .nullable(mask, inner:
// .enum8) wrapper, and decode(String.self) read the column without
// unwrapping that wrapper - so Nullable(Enum) -> String / String? threw a
// type mismatch on non-null rows. Routing String decode through
// nonNullColumn (as the FixedString/wrapper decoders already do) unwraps the
// nullable shell: a present row yields the enum name, an absent row yields
// nil for an Optional field and throws for a required one.
@Suite("a Nullable(Enum) column decodes into a Swift String through the null mask")
struct NullableEnumToStringDecodeTests {

    private struct OptionalRow: Decodable {
        let status: String?
    }

    private struct RequiredRow: Decodable {
        let status: String
    }

    private static let mapping = [
        ClickHouseEnumPair(name: "active", value: 1),
        ClickHouseEnumPair(name: "banned", value: 2),
    ]

    @Test("present rows yield the enum name, an absent row yields nil")
    func optionalReadsThroughMask() throws {
        let inner = ClickHouseTypedColumn.enum8([1, 2, 0], mapping: Self.mapping)
        let column = ClickHouseNamedColumn(name: "status", column: .nullable(mask: [false, false, true], inner: inner))
        let rows = try ClickHouseCodableDecoder.decodeRows(type: OptionalRow.self, columns: [column], rowCount: 3)
        #expect(rows.map(\.status) == ["active", "banned", nil])
    }

    @Test("a required String field reads present nullable-enum rows")
    func requiredReadsPresentRows() throws {
        let inner = ClickHouseTypedColumn.enum8([2, 1], mapping: Self.mapping)
        let column = ClickHouseNamedColumn(name: "status", column: .nullable(mask: [false, false], inner: inner))
        let rows = try ClickHouseCodableDecoder.decodeRows(type: RequiredRow.self, columns: [column], rowCount: 2)
        #expect(rows.map(\.status) == ["banned", "active"])
    }

    @Test("a required String field over a NULL nullable-enum row throws")
    func requiredOverNullThrows() {
        let inner = ClickHouseTypedColumn.enum8([0], mapping: Self.mapping)
        let column = ClickHouseNamedColumn(name: "status", column: .nullable(mask: [true], inner: inner))
        #expect(throws: (any Error).self) {
            _ = try ClickHouseCodableDecoder.decodeRows(type: RequiredRow.self, columns: [column], rowCount: 1)
        }
    }
}
