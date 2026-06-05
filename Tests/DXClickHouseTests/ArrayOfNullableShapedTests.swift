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

// Array(Nullable(Decimal(P,S))) and Array(Nullable(DateTime64(P))) carry their
// precision/scale on the column element, so each uses a dedicated path that
// reads the parameters from the element (decode) and infers them from the
// present elements of the row (encode), like Array(Nullable(FixedString)).
@Suite("Array(Nullable(Decimal/DateTime64)) round-trips and carries its parameters")
struct ArrayOfNullableShapedTests {

    private struct DecimalRow: Codable, Sendable, Equatable { let v: [ClickHouseDecimal?] }
    private struct DateTime64Row: Codable, Sendable, Equatable { let v: [ClickHouseDateTime64?] }

    @Test("a [ClickHouseDecimal?] batch round-trips and preserves precision/scale")
    func decimalRoundTrips() throws {
        let rows = [
            DecimalRow(v: [ClickHouseDecimal(unscaled: 150, precision: 10, scale: 2), nil, ClickHouseDecimal(unscaled: 300, precision: 10, scale: 2)]),
            DecimalRow(v: [nil, ClickHouseDecimal(unscaled: 50, precision: 10, scale: 2)]),
        ]
        let columns = try ClickHouseRowEncoder().encode(rows)
        #expect(columns[0].column.typeName == "Array(Nullable(Decimal(10, 2)))")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: DecimalRow.self, columns: columns, rowCount: rows.count)
        #expect(decoded == rows)
    }

    @Test("a [ClickHouseDateTime64?] batch round-trips and preserves precision")
    func dateTime64RoundTrips() throws {
        let rows = [
            DateTime64Row(v: [ClickHouseDateTime64(ticks: 1000, precision: 3), nil]),
            DateTime64Row(v: [ClickHouseDateTime64(ticks: 2000, precision: 3)]),
        ]
        let columns = try ClickHouseRowEncoder().encode(rows)
        #expect(columns[0].column.typeName == "Array(Nullable(DateTime64(3)))")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: DateTime64Row.self, columns: columns, rowCount: rows.count)
        #expect(decoded == rows)
    }

    @Test("a Decimal row with no present element cannot establish precision/scale")
    func allNilDecimalRejected() {
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseRowEncoder().encode([DecimalRow(v: [nil, nil])])
        }
    }
}
