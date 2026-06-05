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

// Array(Nullable(Enum8/16)) carries its name->value mapping on the column
// element. Decode reads the mapping from the element; encode infers it from
// the present elements of the row and validates it (the same checks as the
// non-nullable enum array). This is the last element type, completing
// Array(Nullable(T)) for every supported inner type.
@Suite("Array(Nullable(Enum8/16)) round-trips and carries its mapping")
struct ArrayOfNullableEnumTests {

    private struct Enum8Row: Codable, Sendable, Equatable { let v: [ClickHouseEnum8?] }
    private struct Enum16Row: Codable, Sendable, Equatable { let v: [ClickHouseEnum16?] }

    @Test("a [ClickHouseEnum8?] batch round-trips with interspersed NULLs")
    func enum8RoundTrips() throws {
        let mapping = [ClickHouseEnumPair(name: "active", value: 1), ClickHouseEnumPair(name: "closed", value: 2)]
        let rows = [
            Enum8Row(v: [ClickHouseEnum8(value: 1, mapping: mapping), nil, ClickHouseEnum8(value: 2, mapping: mapping)]),
            Enum8Row(v: [nil, ClickHouseEnum8(value: 1, mapping: mapping)]),
        ]
        let columns = try ClickHouseRowEncoder().encode(rows)
        #expect(columns[0].column.typeName == "Array(Nullable(Enum8('active' = 1, 'closed' = 2)))")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Enum8Row.self, columns: columns, rowCount: rows.count)
        #expect(decoded == rows)
    }

    @Test("a [ClickHouseEnum16?] batch round-trips with interspersed NULLs")
    func enum16RoundTrips() throws {
        let mapping = [ClickHouseEnumPair(name: "a", value: 100), ClickHouseEnumPair(name: "b", value: 200)]
        let rows = [Enum16Row(v: [ClickHouseEnum16(value: 100, mapping: mapping), nil, ClickHouseEnum16(value: 200, mapping: mapping)])]
        let columns = try ClickHouseRowEncoder().encode(rows)
        #expect(columns[0].column.typeName == "Array(Nullable(Enum16('a' = 100, 'b' = 200)))")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Enum16Row.self, columns: columns, rowCount: rows.count)
        #expect(decoded == rows)
    }
}
