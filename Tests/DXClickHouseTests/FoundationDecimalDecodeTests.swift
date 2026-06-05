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

// Foundation's Decimal is the idiomatic Swift type for money. A Decimal(P,S)
// column should decode straight into a `let price: Decimal` field instead of
// forcing the raw-limb ClickHouseDecimal. Foundation.Decimal holds 38
// significant digits, so Decimal32/64/128 (P<=38) decode exactly; a
// Decimal256 (P>38) would lose precision silently and is rejected with a
// clear error pointing back to ClickHouseDecimal.
@Suite("a ClickHouse Decimal column decodes into a Foundation Decimal")
struct FoundationDecimalDecodeTests {

    private struct Row: Decodable {
        let price: Decimal
    }

    private static func decodeOne(_ value: ClickHouseDecimal) throws -> Decimal {
        let column = ClickHouseNamedColumn(name: "price", column: .decimal([value], precision: value.precision, scale: value.scale))
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: [column], rowCount: 1)
        return rows[0].price
    }

    @Test("a positive scaled value decodes exactly")
    func positiveScaled() throws {
        let decoded = try Self.decodeOne(ClickHouseDecimal(unscaled: 123_456, precision: 10, scale: 2))
        #expect(decoded == Decimal(123_456) / Decimal(100))
    }

    @Test("a negative value decodes with its sign")
    func negative() throws {
        let decoded = try Self.decodeOne(ClickHouseDecimal(unscaled: -98_765, precision: 10, scale: 3))
        #expect(decoded == Decimal(-98_765) / Decimal(1000))
    }

    @Test("a scale-zero value decodes as a whole number")
    func wholeNumber() throws {
        let decoded = try Self.decodeOne(ClickHouseDecimal(unscaled: 42, precision: 9, scale: 0))
        #expect(decoded == Decimal(42))
    }

    @Test("a Decimal256 beyond Foundation.Decimal range is rejected")
    func decimal256Rejected() {
        let value = ClickHouseDecimal(limb0: 1, limb1: 0, limb2: 0, limb3: 0, precision: 50, scale: 0)
        let column = ClickHouseNamedColumn(name: "price", column: .decimal([value], precision: 50, scale: 0))
        #expect(throws: (any Error).self) {
            _ = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: [column], rowCount: 1)
        }
    }
}
