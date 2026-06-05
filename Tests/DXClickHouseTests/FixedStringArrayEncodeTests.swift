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

// Array(FixedString(N)) decodes natively into [ClickHouseFixedString] (a
// row's set of fixed-width identifiers), but the encode side had native
// array support only for the basic scalar element types, so inserting a
// [ClickHouseFixedString] field failed with an opaque "nested container"
// error — a select/insert asymmetry for a common identifier column.
// ClickHouseFixedString carries its width, so a non-empty array's element
// type is unambiguous; an empty array cannot infer it and is rejected with
// guidance toward the explicit ClickHouseArray.
@Suite("[ClickHouseFixedString] arrays insert symmetrically with how they select")
struct FixedStringArrayEncodeTests {

    private struct Row: Codable, Sendable, Equatable {
        let refs: [ClickHouseFixedString]
    }

    @Test("a [ClickHouseFixedString] field round-trips through encode then decode")
    func roundTrips() throws {
        let original = [Row(refs: [
            ClickHouseFixedString(bytes: Array("ABCD".utf8), length: 4),
            ClickHouseFixedString(bytes: Array("WXYZ".utf8), length: 4),
        ])]
        let columns = try ClickHouseRowEncoder().encode(original)
        #expect(columns[0].column.typeName == "Array(FixedString(4))")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 1)
        #expect(decoded == original)
    }

    @Test("an empty [ClickHouseFixedString] is rejected with actionable guidance")
    func emptyArrayRejected() {
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseRowEncoder().encode([Row(refs: [])])
        }
    }

    @Test("a mixed-length array is rejected")
    func mixedLengthRejected() {
        let row = Row(refs: [
            ClickHouseFixedString(bytes: Array("AB".utf8), length: 2),
            ClickHouseFixedString(bytes: Array("ABCD".utf8), length: 4),
        ])
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseRowEncoder().encode([row])
        }
    }
}
