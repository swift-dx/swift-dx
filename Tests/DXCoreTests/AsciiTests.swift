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
struct AsciiTests {

    @Test
    func ascii_whitespaceConstantsMatchCharacterCodes() {
        #expect(Ascii.horizontalTab == 0x09)
        #expect(Ascii.lineFeed == 0x0a)
        #expect(Ascii.carriageReturn == 0x0d)
        #expect(Ascii.space == UInt8(ascii: " "))
    }

    @Test
    func ascii_punctuationConstantsMatchCharacterCodes() {
        #expect(Ascii.exclamation == UInt8(ascii: "!"))
        #expect(Ascii.quote == UInt8(ascii: "\""))
        #expect(Ascii.dollar == UInt8(ascii: "$"))
        #expect(Ascii.asterisk == UInt8(ascii: "*"))
        #expect(Ascii.plus == UInt8(ascii: "+"))
        #expect(Ascii.hyphen == UInt8(ascii: "-"))
        #expect(Ascii.dot == UInt8(ascii: "."))
        #expect(Ascii.slash == UInt8(ascii: "/"))
        #expect(Ascii.colon == UInt8(ascii: ":"))
        #expect(Ascii.equals == UInt8(ascii: "="))
        #expect(Ascii.greaterThan == UInt8(ascii: ">"))
        #expect(Ascii.backslash == UInt8(ascii: "\\"))
        #expect(Ascii.underscore == UInt8(ascii: "_"))
        #expect(Ascii.tilde == UInt8(ascii: "~"))
    }

    @Test
    func ascii_digitConstantsMatchCharacterCodes() {
        #expect(Ascii.digitZero == UInt8(ascii: "0"))
        #expect(Ascii.digitNine == UInt8(ascii: "9"))
        #expect(Ascii.digitNine - Ascii.digitZero == 9)
    }

    @Test
    func ascii_upperCaseLetterConstantsMatchCharacterCodes() {
        #expect(Ascii.upperA == UInt8(ascii: "A"))
        #expect(Ascii.upperB == UInt8(ascii: "B"))
        #expect(Ascii.upperD == UInt8(ascii: "D"))
        #expect(Ascii.upperE == UInt8(ascii: "E"))
        #expect(Ascii.upperF == UInt8(ascii: "F"))
        #expect(Ascii.upperG == UInt8(ascii: "G"))
        #expect(Ascii.upperH == UInt8(ascii: "H"))
        #expect(Ascii.upperI == UInt8(ascii: "I"))
        #expect(Ascii.upperM == UInt8(ascii: "M"))
        #expect(Ascii.upperN == UInt8(ascii: "N"))
        #expect(Ascii.upperO == UInt8(ascii: "O"))
        #expect(Ascii.upperP == UInt8(ascii: "P"))
        #expect(Ascii.upperR == UInt8(ascii: "R"))
        #expect(Ascii.upperS == UInt8(ascii: "S"))
        #expect(Ascii.upperT == UInt8(ascii: "T"))
        #expect(Ascii.upperU == UInt8(ascii: "U"))
        #expect(Ascii.upperZ == UInt8(ascii: "Z"))
        #expect(Ascii.upperZ - Ascii.upperA == 25)
    }

    @Test
    func ascii_lowerCaseLetterConstantsMatchCharacterCodes() {
        #expect(Ascii.lowerA == UInt8(ascii: "a"))
        #expect(Ascii.lowerZ == UInt8(ascii: "z"))
        #expect(Ascii.lowerZ - Ascii.lowerA == 25)
    }

    @Test
    func ascii_printableRangeBoundariesAreCorrect() {
        #expect(Ascii.exclamation == 0x21)
        #expect(Ascii.tilde == 0x7e)
        #expect(Ascii.tilde - Ascii.exclamation == 93)
    }
}
