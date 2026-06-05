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

// Money values usually arrive as text (JSON, forms, logs). ClickHouseDecimal
// could render to a string (description) but only be built from a raw
// unscaled integer, so a caller had to compute unscaled = value * 10^scale
// by hand. init(_:precision:scale:) parses fixed-point decimal text into the
// unscaled value at the column's scale and round-trips with description. The
// magnitude is parsed into 256-bit limbs, so Decimal128/256 values beyond
// Int64 are supported directly from text; a magnitude with more significant
// digits than the declared precision is rejected (see WideDecimalStringInit).
@Suite("ClickHouseDecimal parses fixed-point decimal text")
struct DecimalStringInitTests {

    @Test("a scaled value round-trips through description")
    func roundTrips() throws {
        #expect(try ClickHouseDecimal("1234.56", precision: 10, scale: 2).description == "1234.56")
        #expect(try ClickHouseDecimal("0.05", precision: 5, scale: 2).description == "0.05")
        #expect(try ClickHouseDecimal("-1234.56", precision: 10, scale: 2).description == "-1234.56")
        #expect(try ClickHouseDecimal("42", precision: 9, scale: 0).description == "42")
    }

    @Test("a fraction shorter than the scale is right-padded")
    func shortFractionPads() throws {
        #expect(try ClickHouseDecimal("1234.5", precision: 10, scale: 2).description == "1234.50")
        #expect(try ClickHouseDecimal(".5", precision: 5, scale: 2).description == "0.50")
    }

    @Test("a fraction longer than the scale is rejected")
    func longFractionRejected() {
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseDecimal("1.234", precision: 10, scale: 2)
        }
    }

    @Test("the Int64 boundary values parse exactly")
    func int64Boundaries() throws {
        #expect(try ClickHouseDecimal("9223372036854775807", precision: 19, scale: 0).description == "9223372036854775807")
        #expect(try ClickHouseDecimal("-9223372036854775808", precision: 19, scale: 0).description == "-9223372036854775808")
    }

    @Test("values just past the Int64 boundary parse as Decimal128")
    func justPastInt64() throws {
        #expect(try ClickHouseDecimal("9223372036854775808", precision: 20, scale: 0).description == "9223372036854775808")
        #expect(try ClickHouseDecimal("-9223372036854775809", precision: 20, scale: 0).description == "-9223372036854775809")
    }

    @Test("a 30-digit value beyond Int64 parses into Decimal128")
    func beyondInt64ParsesWide() throws {
        let text = "123456789012345678901234567890"
        #expect(try ClickHouseDecimal(text, precision: 38, scale: 0).description == text)
    }

    @Test("non-numeric text is rejected")
    func nonNumericRejected() {
        for bad in ["abc", "1.2.3", "12a", "--1", ""] {
            #expect(throws: ClickHouseError.self) {
                _ = try ClickHouseDecimal(bad, precision: 10, scale: 2)
            }
        }
    }
}
