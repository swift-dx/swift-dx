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
import Foundation
import Testing

// ClickHouseDecimal renders its unscaled integer at the declared scale: the
// decimal point sits `scale` digits from the right, with leading zeros added
// when the unscaled magnitude has fewer digits than the scale, trailing zeros
// preserved, and the sign kept. These edge cases (scale larger than the digit
// count, exact zero, trailing-zero fractions, negatives) are where a string
// renderer for a financial type most often goes wrong.
@Suite("Decimal description renders scale, sign, and zero padding")
struct DecimalDescriptionRoundTripTests {

    @Test("unscaled-plus-scale renders to the expected decimal text")
    func rendersExpectedText() {
        #expect(ClickHouseDecimal(unscaled: 5, precision: 10, scale: 3).description == "0.005")
        #expect(ClickHouseDecimal(unscaled: 0, precision: 10, scale: 0).description == "0")
        #expect(ClickHouseDecimal(unscaled: -150, precision: 10, scale: 2).description == "-1.50")
        #expect(ClickHouseDecimal(unscaled: 100, precision: 10, scale: 0).description == "100")
        #expect(ClickHouseDecimal(unscaled: 10, precision: 10, scale: 2).description == "0.10")
        #expect(ClickHouseDecimal(unscaled: -1, precision: 10, scale: 3).description == "-0.001")
        #expect(ClickHouseDecimal(unscaled: 1, precision: 10, scale: 0).description == "1")
        #expect(ClickHouseDecimal(unscaled: -1, precision: 10, scale: 0).description == "-1")
    }
}
