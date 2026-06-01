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
struct HexTests {

    @Test
    func encodeLower_rendersEachByteAsTwoLowercaseDigits() {
        #expect(Hex.encodeLower([0x00, 0x0f, 0x10, 0xff, 0xab]) == "000f10ffab")
    }

    @Test
    func encodeLower_emptyInputProducesEmptyString() {
        #expect(Hex.encodeLower([]) == "")
    }

    @Test
    func decode_parsesLowercaseAndUppercaseDigits() throws {
        #expect(try Hex.decode("00ff10") == [0x00, 0xff, 0x10])
        #expect(try Hex.decode("DEADbeef") == [0xde, 0xad, 0xbe, 0xef])
    }

    @Test
    func decode_oddLengthThrows() {
        #expect(throws: HexError.oddLength) {
            try Hex.decode("abc")
        }
    }

    @Test
    func decode_invalidCharacterThrows() {
        #expect(throws: HexError.invalidCharacter) {
            try Hex.decode("zz")
        }
    }

    @Test
    func encodeThenDecode_roundTripsArbitraryBytes() throws {
        let bytes: [UInt8] = (0...255).map { UInt8($0) }
        #expect(try Hex.decode(Hex.encodeLower(bytes)) == bytes)
    }
}
