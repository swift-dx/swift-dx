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

// Array(Decimal(P, S)) decodes natively into [ClickHouseDecimal], but the
// encode side previously had native array support only for the basic scalar
// element types, so inserting a [ClickHouseDecimal] field failed with an
// opaque "nested container" error — a select/insert asymmetry for a common
// financial column. ClickHouseDecimal carries its own precision and scale,
// so a non-empty array's element type is unambiguous; an empty array cannot
// infer it and is rejected with guidance toward the explicit ClickHouseArray.
@Suite("[ClickHouseDecimal] arrays insert symmetrically with how they select")
struct DecimalArrayEncodeTests {

    private struct Row: Codable, Sendable, Equatable {
        let amounts: [ClickHouseDecimal]
    }

    @Test("a [ClickHouseDecimal] field round-trips through encode then decode")
    func roundTrips() throws {
        let original = [Row(amounts: [
            ClickHouseDecimal(unscaled: 12_345, precision: 9, scale: 2),
            ClickHouseDecimal(unscaled: -678, precision: 9, scale: 2),
        ])]
        let columns = try ClickHouseRowEncoder().encode(original)
        #expect(columns[0].column.typeName == "Array(Decimal(9, 2))")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 1)
        #expect(decoded == original)
    }

    @Test("a wider Decimal(18, 4) array round-trips")
    func roundTripsWideDecimal() throws {
        let original = [Row(amounts: [ClickHouseDecimal(unscaled: 9_000_000_000, precision: 18, scale: 4)])]
        let columns = try ClickHouseRowEncoder().encode(original)
        #expect(columns[0].column.typeName == "Array(Decimal(18, 4))")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 1)
        #expect(decoded == original)
    }

    @Test("an empty [ClickHouseDecimal] is rejected with actionable guidance")
    func emptyArrayRejected() {
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseRowEncoder().encode([Row(amounts: [])])
        }
    }

    @Test("a mixed precision/scale array is rejected")
    func mixedPrecisionRejected() {
        let row = Row(amounts: [
            ClickHouseDecimal(unscaled: 1, precision: 9, scale: 2),
            ClickHouseDecimal(unscaled: 2, precision: 18, scale: 4),
        ])
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseRowEncoder().encode([row])
        }
    }
}
