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

// Array(DateTime64(P)) decodes natively into [ClickHouseDateTime64] (a row's
// sub-second timestamp sequence), but the encode side had native array
// support only for the basic scalar element types, so inserting a
// [ClickHouseDateTime64] field failed with an opaque "nested container"
// error. Each value carries its precision, so a non-empty array is
// unambiguous; an empty array cannot infer it and is rejected with guidance
// toward the explicit ClickHouseArray.
@Suite("[ClickHouseDateTime64] arrays insert symmetrically with how they select")
struct DateTime64ArrayEncodeTests {

    private struct Row: Codable, Sendable, Equatable {
        let stamps: [ClickHouseDateTime64]
    }

    @Test("a [ClickHouseDateTime64] field round-trips through encode then decode")
    func roundTrips() throws {
        let original = [Row(stamps: [
            ClickHouseDateTime64(ticks: 1_700_000_000_000, precision: 3),
            ClickHouseDateTime64(ticks: 1_700_000_000_500, precision: 3),
        ])]
        let columns = try ClickHouseRowEncoder().encode(original)
        #expect(columns[0].column.typeName == "Array(DateTime64(3))")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 1)
        #expect(decoded == original)
    }

    @Test("an empty [ClickHouseDateTime64] is rejected with actionable guidance")
    func emptyArrayRejected() {
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseRowEncoder().encode([Row(stamps: [])])
        }
    }

    @Test("a mixed-precision array is rejected")
    func mixedPrecisionRejected() {
        let row = Row(stamps: [
            ClickHouseDateTime64(ticks: 1, precision: 3),
            ClickHouseDateTime64(ticks: 2, precision: 6),
        ])
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseRowEncoder().encode([row])
        }
    }
}
