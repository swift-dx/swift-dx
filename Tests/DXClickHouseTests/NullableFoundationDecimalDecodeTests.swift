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

// Nullable(Decimal) money columns are common. iter-98 made Decimal decode
// into Foundation.Decimal via nonNullColumn (which unwraps the generic
// .nullable wrapper) and reject Decimal256; a `let price: Decimal?` field
// must read present rows as the value and absent rows as nil through the
// null mask, and a required Decimal over a NULL row must throw.
@Suite("a Nullable(Decimal) column decodes into Foundation Decimal through the mask")
struct NullableFoundationDecimalDecodeTests {

    private struct OptionalRow: Decodable {
        let price: Decimal?
    }

    private struct RequiredRow: Decodable {
        let price: Decimal
    }

    private static func nullableColumn(mask: [Bool]) -> ClickHouseNamedColumn {
        let values = (0..<mask.count).map { ClickHouseDecimal(unscaled: Int64($0 * 100 + 5), precision: 10, scale: 2) }
        return ClickHouseNamedColumn(name: "price", column: .nullable(mask: mask, inner: .decimal(values, precision: 10, scale: 2)))
    }

    @Test("present rows yield the value, an absent row yields nil")
    func optionalReadsThroughMask() throws {
        let column = Self.nullableColumn(mask: [false, true, false])
        let rows = try ClickHouseCodableDecoder.decodeRows(type: OptionalRow.self, columns: [column], rowCount: 3)
        #expect(rows[0].price == Decimal(5) / Decimal(100))
        #expect(rows[1].price == nil)
        #expect(rows[2].price == Decimal(205) / Decimal(100))
    }

    @Test("a required Decimal over a NULL row throws")
    func requiredOverNullThrows() {
        let column = Self.nullableColumn(mask: [true])
        #expect(throws: (any Error).self) {
            _ = try ClickHouseCodableDecoder.decodeRows(type: RequiredRow.self, columns: [column], rowCount: 1)
        }
    }
}
