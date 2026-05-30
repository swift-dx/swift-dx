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
struct JSONParserStringTests {

    @Test
    func decodesQuoteEscape() throws {
        #expect(try JSONParser.parse(#""a\"b""#) == .string("a\"b"))
    }

    @Test
    func decodesBackslashEscape() throws {
        #expect(try JSONParser.parse(#""a\\b""#) == .string("a\\b"))
    }

    @Test
    func decodesSolidusEscape() throws {
        #expect(try JSONParser.parse(#""a\/b""#) == .string("a/b"))
    }

    @Test
    func decodesControlEscapes() throws {
        #expect(try JSONParser.parse(#""\b\f\n\r\t""#) == .string("\u{08}\u{0C}\n\r\t"))
    }

    @Test
    func decodesBasicUnicodeEscape() throws {
        #expect(try JSONParser.parse(#""A""#) == .string("A"))
    }

    @Test
    func decodesUnicodeEscapeWithUppercaseHex() throws {
        #expect(try JSONParser.parse(#""é""#) == .string("é"))
    }

    @Test
    func decodesUnicodeEscapeWithLowercaseHex() throws {
        #expect(try JSONParser.parse(#""é""#) == .string("é"))
    }

    @Test
    func decodesSurrogatePairEmoji() throws {
        #expect(try JSONParser.parse(#""😀""#) == .string("😀"))
    }

    @Test
    func preservesMultibyteUTF8Literal() throws {
        #expect(try JSONParser.parse("\"naïve — 日本\"") == .string("naïve — 日本"))
    }

    @Test
    func rejectsUnescapedControlCharacter() {
        let bytes: [UInt8] = [Ascii.quote, 0x09, Ascii.quote]
        #expect(JSONFixtures.capturedError(bytes, limits: .standard) == .found(.controlCharacterInString(byteOffset: 1)))
    }

    @Test
    func rejectsInvalidEscape() {
        #expect(JSONFixtures.capturedError(#""a\xb""#) == .found(.invalidStringEscape(byteOffset: 3)))
    }

    @Test
    func rejectsTruncatedUnicodeEscape() {
        #expect(JSONFixtures.capturedError(#""\u12""#) == .found(.invalidUnicodeEscape(byteOffset: 5)))
    }

    @Test
    func rejectsNonHexInUnicodeEscape() {
        #expect(JSONFixtures.capturedError(#""\u12zz""#) == .found(.invalidUnicodeEscape(byteOffset: 5)))
    }

    @Test
    func rejectsLoneHighSurrogate() {
        #expect(JSONFixtures.capturedError(#""\uD83D""#) == .found(.unpairedSurrogate(byteOffset: 7)))
    }

    @Test
    func rejectsLoneLowSurrogate() {
        #expect(JSONFixtures.capturedError(#""\uDE00""#) == .found(.unpairedSurrogate(byteOffset: 7)))
    }

    @Test
    func rejectsHighSurrogateFollowedByNonLow() {
        #expect(JSONFixtures.capturedError(#""\uD83DA""#) == .found(.unpairedSurrogate(byteOffset: 7)))
    }

    @Test
    func rejectsInvalidUTF8Bytes() {
        let bytes: [UInt8] = [Ascii.quote, 0xFF, 0xFE, Ascii.quote]
        #expect(JSONFixtures.capturedError(bytes, limits: .standard) == .found(.invalidUTF8(byteOffset: 3)))
    }

    @Test
    func rejectsUnterminatedString() {
        #expect(JSONFixtures.capturedError(#""abc"#) == .found(.unexpectedEndOfInput(byteOffset: 4)))
    }
}
