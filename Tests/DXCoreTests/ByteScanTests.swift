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
@testable import DXCore

@Suite
struct ByteScanTests {

    @Test
    func byteScan_parseIntReadsAsciiDigits() {
        let bytes = Array("12345".utf8)
        #expect(ByteScan.parseInt(bytes, start: 0, end: bytes.count) == 12345)
    }

    @Test
    func byteScan_parseIntStopsAtNonDigit() {
        let bytes = Array("42 99".utf8)
        #expect(ByteScan.parseInt(bytes, start: 0, end: bytes.count) == 42)
    }

    @Test
    func byteScan_parseIntReturnsZeroOnEmptyRange() {
        let bytes = Array("123".utf8)
        #expect(ByteScan.parseInt(bytes, start: 0, end: 0) == 0)
    }

    @Test
    func byteScan_decimalDigitClassifiesAsciiZeroToNine() {
        for raw: UInt8 in 0x30...0x39 {
            guard case .digit(let value) = ByteScan.decimalDigit(of: raw) else {
                Issue.record("expected digit for byte \(raw)")
                return
            }
            #expect(value == raw - 0x30)
        }
        #expect(ByteScan.decimalDigit(of: 0x2f) == .invalid)
        #expect(ByteScan.decimalDigit(of: 0x3a) == .invalid)
    }

    @Test
    func byteScan_base36DigitHandlesDigitZero() {
        #expect(ByteScan.base36Digit(of: 0x30) == .digit(0))
    }

    @Test
    func byteScan_base36DigitHandlesLowerAsTen() {
        #expect(ByteScan.base36Digit(of: 0x61) == .digit(10))
    }

    @Test
    func byteScan_base36DigitHandlesLowerZAsThirtyFive() {
        #expect(ByteScan.base36Digit(of: 0x7a) == .digit(35))
    }

    @Test
    func byteScan_base36DigitRejectsUppercase() {
        #expect(ByteScan.base36Digit(of: 0x5a) == .invalid)
    }

    @Test
    func byteScan_keyMatchesDetectsExactSubstring() {
        let bytes = Array("hello world".utf8)
        #expect(ByteScan.keyMatches(bytes, at: 6, key: Array("world".utf8)))
        #expect(!ByteScan.keyMatches(bytes, at: 0, key: Array("world".utf8)))
    }

    @Test
    func byteScan_skipSpacesAdvancesToFirstNonSpace() {
        let bytes = Array("   abc".utf8)
        #expect(ByteScan.skipSpaces(bytes, from: 0, end: bytes.count) == 3)
    }
}
