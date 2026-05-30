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
struct JSONParserErrorTests {

    @Test
    func rejectsEmptyInput() {
        #expect(JSONFixtures.capturedError("") == .found(.emptyInput))
    }

    @Test
    func rejectsWhitespaceOnlyInput() {
        #expect(JSONFixtures.capturedError("   ") == .found(.unexpectedEndOfInput(byteOffset: 3)))
    }

    @Test
    func rejectsTruncatedLiteral() {
        #expect(JSONFixtures.capturedError("tru") == .found(.invalidLiteral(byteOffset: 0)))
    }

    @Test
    func rejectsMisspelledLiteral() {
        #expect(JSONFixtures.capturedError("nulla") == .found(.trailingData(byteOffset: 4)))
    }

    @Test
    func rejectsTrailingDataAfterValue() {
        #expect(JSONFixtures.capturedError("true false") == .found(.trailingData(byteOffset: 5)))
    }

    @Test
    func rejectsUnterminatedObject() {
        #expect(JSONFixtures.capturedError("{") == .found(.unexpectedEndOfInput(byteOffset: 1)))
    }

    @Test
    func rejectsMissingColon() {
        #expect(JSONFixtures.capturedError(#"{"a"}"#) == .found(.unexpectedByte(byteOffset: 4, found: Ascii.braceClose)))
    }

    @Test
    func rejectsTrailingCommaInArray() {
        #expect(JSONFixtures.capturedError("[1,]") == .found(.invalidNumber(byteOffset: 3)))
    }

    @Test
    func rejectsTrailingCommaInObject() {
        #expect(JSONFixtures.capturedError(#"{"a":1,}"#) == .found(.unexpectedByte(byteOffset: 7, found: Ascii.braceClose)))
    }

    @Test
    func rejectsMissingCommaInArray() {
        #expect(JSONFixtures.capturedError("[1 2]") == .found(.unexpectedByte(byteOffset: 3, found: Ascii.digitZero + 2)))
    }

    @Test
    func rejectsNonStringObjectKey() {
        #expect(JSONFixtures.capturedError("{1:2}") == .found(.unexpectedByte(byteOffset: 1, found: Ascii.digitZero + 1)))
    }
}
