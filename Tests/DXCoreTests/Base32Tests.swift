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
struct Base32Tests {

    @Test
    func base32_decodesSingleByte() throws {
        let decoded = try Base32.decode("MY")
        #expect(decoded == [0x66])
    }

    @Test
    func base32_decodesShortMessage() throws {
        let decoded = try Base32.decode("MZXW6")
        #expect(decoded == Array("foo".utf8))
    }

    @Test
    func base32_decodesLongerMessage() throws {
        let decoded = try Base32.decode("MZXW6YTBOI")
        #expect(decoded == Array("foobar".utf8))
    }

    @Test
    func base32_acceptsLowercase() throws {
        let decoded = try Base32.decode("mzxw6")
        #expect(decoded == Array("foo".utf8))
    }

    @Test
    func base32_rejectsInvalidCharacter() {
        #expect(throws: Base32Error.self) {
            _ = try Base32.decode("MZXW6!")
        }
    }

    @Test
    func base32_ignoresPadding() throws {
        let decoded = try Base32.decode("MZXW6===")
        #expect(decoded == Array("foo".utf8))
    }
}
