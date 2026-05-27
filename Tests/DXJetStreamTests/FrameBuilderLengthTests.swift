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

import Testing
@testable import DXJetStream

@Suite
struct FrameBuilderLengthTests {

    @Test
    func decimalLength_boundaryValues() {
        #expect(FrameBuilder.decimalLength(0) == 1)
        #expect(FrameBuilder.decimalLength(1) == 1)
        #expect(FrameBuilder.decimalLength(9) == 1)
        #expect(FrameBuilder.decimalLength(10) == 2)
        #expect(FrameBuilder.decimalLength(99) == 2)
        #expect(FrameBuilder.decimalLength(100) == 3)
        #expect(FrameBuilder.decimalLength(999) == 3)
        #expect(FrameBuilder.decimalLength(1_000) == 4)
        #expect(FrameBuilder.decimalLength(9_999) == 4)
        #expect(FrameBuilder.decimalLength(10_000) == 5)
        #expect(FrameBuilder.decimalLength(UInt64.max) == 20)
    }

    @Test
    func base36Length_boundaryValues() {
        #expect(FrameBuilder.base36Length(0) == 1)
        #expect(FrameBuilder.base36Length(1) == 1)
        #expect(FrameBuilder.base36Length(35) == 1)
        #expect(FrameBuilder.base36Length(36) == 2)
        #expect(FrameBuilder.base36Length(1_295) == 2)
        #expect(FrameBuilder.base36Length(1_296) == 3)
        #expect(FrameBuilder.base36Length(46_655) == 3)
        #expect(FrameBuilder.base36Length(46_656) == 4)
        #expect(FrameBuilder.base36Length(UInt64.max) == 13)
    }

    @Test
    func decimalLength_matchesStringFormattedLength() {
        for value: UInt64 in [0, 1, 7, 42, 123, 10_000, 1_000_000, 100_000_000_000] {
            #expect(FrameBuilder.decimalLength(value) == String(value).count)
        }
    }

    @Test
    func base36Length_matchesStringFormattedLength() {
        for value: UInt64 in [0, 1, 35, 36, 100, 1_295, 1_296, 1_000_000_000] {
            #expect(FrameBuilder.base36Length(value) == String(value, radix: 36).count)
        }
    }

    @Test
    func maxDigitConstants_matchUInt64MaxLengths() {
        #expect(FrameBuilder.maxDecimalDigitsUInt64 == String(UInt64.max).count)
        #expect(FrameBuilder.maxBase36DigitsUInt64 == String(UInt64.max, radix: 36).count)
        #expect(FrameBuilder.maxDecimalDigitsUInt64 == FrameBuilder.decimalLength(UInt64.max))
        #expect(FrameBuilder.maxBase36DigitsUInt64 == FrameBuilder.base36Length(UInt64.max))
    }

    @Test
    func maxDigitConstants_haveExpectedValues() {
        #expect(FrameBuilder.maxDecimalDigitsUInt64 == 20)
        #expect(FrameBuilder.maxBase36DigitsUInt64 == 13)
    }
}
