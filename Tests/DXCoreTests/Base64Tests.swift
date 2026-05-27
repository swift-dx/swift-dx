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
struct Base64Tests {

    @Test
    func base64_decodesStandardAlphabet() throws {
        let decoded = try Base64.decode("Zm9v")
        #expect(decoded == Array("foo".utf8))
    }

    @Test
    func base64_decodesUrlSafeAlphabet() throws {
        let decoded = try Base64.decode("Zm9v_-")
        #expect(decoded.count == 4)
    }

    @Test
    func base64_ignoresPadding() throws {
        let decoded = try Base64.decode("Zg==")
        #expect(decoded == [0x66])
    }

    @Test
    func base64_ignoresWhitespace() throws {
        let decoded = try Base64.decode("Zm9v\n  Zm9v")
        #expect(decoded == Array("foofoo".utf8))
    }

    @Test
    func base64_rejectsInvalidCharacter() {
        #expect(throws: Base64Error.self) {
            _ = try Base64.decode("zZ!")
        }
    }
}
