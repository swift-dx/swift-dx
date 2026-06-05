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

// A Decimal column that a caller cannot read the value of is half-useless:
// before this, ClickHouseDecimal exposed only the four raw little-endian
// limbs plus precision/scale, forcing callers to hand-reassemble
// signedMagnitude / 10^scale. The value must render as its exact decimal
// string (lossless for the full Decimal256 range, which exceeds
// Foundation.Decimal's 38 significant digits), with the point placed scale
// digits from the right and trailing zeros preserved.
@Suite("ClickHouseDecimal renders its exact decimal value as a string")
struct DecimalDescriptionTests {

    @Test("a positive value places the point scale digits from the right")
    func positiveScaled() {
        let decimal = ClickHouseDecimal(unscaled: 123_456, precision: 10, scale: 2)
        #expect(decimal.description == "1234.56")
        #expect("\(decimal)" == "1234.56")
    }

    @Test("a value shorter than the scale is left-padded with a leading zero")
    func smallerThanScale() {
        #expect(ClickHouseDecimal(unscaled: 5, precision: 10, scale: 2).description == "0.05")
    }

    @Test("scale zero renders the bare integer")
    func zeroScale() {
        #expect(ClickHouseDecimal(unscaled: 42, precision: 10, scale: 0).description == "42")
    }

    @Test("a negative value carries a single leading minus")
    func negativeScaled() {
        #expect(ClickHouseDecimal(unscaled: -123_456, precision: 10, scale: 2).description == "-1234.56")
        #expect(ClickHouseDecimal(unscaled: -1, precision: 10, scale: 0).description == "-1")
    }

    @Test("zero keeps its full scale and never renders a minus")
    func zeroValue() {
        #expect(ClickHouseDecimal(unscaled: 0, precision: 10, scale: 4).description == "0.0000")
    }

    @Test("trailing fractional zeros are preserved to the declared scale")
    func trailingZeros() {
        #expect(ClickHouseDecimal(unscaled: 15_000, precision: 10, scale: 4).description == "1.5000")
    }

    @Test("a magnitude beyond 64 bits uses the high limbs losslessly")
    func wideMagnitude() {
        let twoToThe64 = ClickHouseDecimal(limb0: 0, limb1: 1, limb2: 0, limb3: 0, precision: 40, scale: 0)
        #expect(twoToThe64.description == "18446744073709551616")
        let scaled = ClickHouseDecimal(limb0: 0, limb1: 1, limb2: 0, limb3: 0, precision: 40, scale: 4)
        #expect(scaled.description == "1844674407370955.1616")
    }
}
