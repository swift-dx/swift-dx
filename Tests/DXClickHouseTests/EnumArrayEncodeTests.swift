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

import DXClickHouse
import Testing

// Array(Enum8/Enum16) decodes natively into [ClickHouseEnum8] /
// [ClickHouseEnum16], but the encode side had native array support only for
// the basic scalar element types, so inserting an enum array field failed
// with an opaque "nested container" error. Each value carries its name
// mapping, so a non-empty array is unambiguous. As with the scalar enum
// encode, the mapping and every ordinal are validated at the boundary; an
// empty array cannot infer the mapping and is rejected toward ClickHouseArray.
@Suite("[ClickHouseEnum8/16] arrays insert symmetrically with how they select")
struct EnumArrayEncodeTests {

    private struct Row8: Codable, Sendable, Equatable { let states: [ClickHouseEnum8] }
    private struct Row16: Codable, Sendable, Equatable { let codes: [ClickHouseEnum16] }

    private static let mapping8 = [
        ClickHouseEnumPair(name: "active", value: 1),
        ClickHouseEnumPair(name: "closed", value: 2),
    ]
    private static let mapping16 = [
        ClickHouseEnumPair(name: "a", value: 100),
        ClickHouseEnumPair(name: "b", value: 200),
    ]

    @Test("a [ClickHouseEnum8] field round-trips through encode then decode")
    func enum8RoundTrips() throws {
        let original = [Row8(states: [
            ClickHouseEnum8(value: 1, mapping: Self.mapping8),
            ClickHouseEnum8(value: 2, mapping: Self.mapping8),
        ])]
        let columns = try ClickHouseRowEncoder().encode(original)
        #expect(columns[0].column.typeName == "Array(Enum8('active' = 1, 'closed' = 2))")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Row8.self, columns: columns, rowCount: 1)
        #expect(decoded == original)
    }

    @Test("a [ClickHouseEnum16] field round-trips through encode then decode")
    func enum16RoundTrips() throws {
        let original = [Row16(codes: [
            ClickHouseEnum16(value: 100, mapping: Self.mapping16),
            ClickHouseEnum16(value: 200, mapping: Self.mapping16),
        ])]
        let columns = try ClickHouseRowEncoder().encode(original)
        #expect(columns[0].column.typeName == "Array(Enum16('a' = 100, 'b' = 200))")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Row16.self, columns: columns, rowCount: 1)
        #expect(decoded == original)
    }

    @Test("an empty enum array is rejected with actionable guidance")
    func emptyArrayRejected() {
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseRowEncoder().encode([Row8(states: [])])
        }
    }

    @Test("a mixed-mapping enum array is rejected")
    func mixedMappingRejected() {
        let row = Row8(states: [
            ClickHouseEnum8(value: 1, mapping: Self.mapping8),
            ClickHouseEnum8(value: 1, mapping: [ClickHouseEnumPair(name: "other", value: 1)]),
        ])
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseRowEncoder().encode([row])
        }
    }

    @Test("an ordinal absent from the mapping is rejected, as in the scalar path")
    func outOfMappingOrdinalRejected() {
        let row = Row8(states: [ClickHouseEnum8(value: 9, mapping: Self.mapping8)])
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseRowEncoder().encode([row])
        }
    }
}
