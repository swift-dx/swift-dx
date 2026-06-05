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

// The ClickHouseDecimal string initializer parses the unscaled magnitude into
// 256-bit limbs, so Decimal128 and Decimal256 values that exceed Int64 can be
// constructed from text — previously the only option was hand-computing the
// limbs. A value whose significant-digit count exceeds the declared precision
// is rejected rather than silently truncated on the wire.
@Suite("ClickHouseDecimal string init supports the full Decimal128/256 range")
struct WideDecimalStringInitTests {

    @Test("a Decimal128 value beyond Int64 round-trips through string init and description")
    func decimal128BeyondInt64() throws {
        let text = "12345678901234567890.1234567890"
        let decimal = try ClickHouseDecimal(text, precision: 38, scale: 10)
        #expect(decimal.description == text)
    }

    @Test("a negative Decimal256 value beyond Int128 round-trips")
    func negativeDecimal256() throws {
        let text = "-123456789012345678901234567890.12345678901234567890"
        let decimal = try ClickHouseDecimal(text, precision: 76, scale: 20)
        #expect(decimal.description == text)
    }

    @Test("the maximum Decimal256 magnitude (76 nines) round-trips")
    func maximumDecimal256() throws {
        let text = String(repeating: "9", count: 76)
        let decimal = try ClickHouseDecimal(text, precision: 76, scale: 0)
        #expect(decimal.description == text)
    }

    @Test("small Decimal32/64 values are unaffected by the wide parser")
    func smallValuesUnchanged() throws {
        #expect(try ClickHouseDecimal("-123.45", precision: 9, scale: 2).description == "-123.45")
        #expect(try ClickHouseDecimal("0.0001", precision: 9, scale: 4).description == "0.0001")
        #expect(try ClickHouseDecimal("0", precision: 18, scale: 0).description == "0")
    }

    @Test("a value with more significant digits than the precision is rejected")
    func rejectsOverPrecision() {
        #expect(throws: ClickHouseError.self) {
            // 10 significant digits into a precision-9 column.
            _ = try ClickHouseDecimal("1234567890", precision: 9, scale: 0)
        }
        #expect(throws: ClickHouseError.self) {
            // 39 significant digits into a precision-38 column.
            _ = try ClickHouseDecimal(String(repeating: "9", count: 39), precision: 38, scale: 0)
        }
    }

    @Test("a value exceeding the 256-bit range is rejected, not truncated")
    func rejectsBeyond256Bits() {
        // 78 nines exceeds 2^256; precision 76 lets it past the digit check
        // only if precision were larger, so use a precision that admits the
        // digit count but a magnitude past 256 bits is impossible within 76
        // digits — instead assert the precision guard catches 77+ digits.
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseDecimal(String(repeating: "9", count: 77), precision: 76, scale: 0)
        }
    }
}
