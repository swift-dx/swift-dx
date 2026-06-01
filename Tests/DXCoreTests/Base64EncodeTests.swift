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
struct Base64EncodeTests {

    @Test
    func encode_emptyInputProducesEmptyString() {
        #expect(Base64.encode([]) == "")
    }

    @Test(arguments: [
        ("f", "Zg=="),
        ("fo", "Zm8="),
        ("foo", "Zm9v"),
        ("foob", "Zm9vYg=="),
        ("fooba", "Zm9vYmE="),
        ("foobar", "Zm9vYmFy"),
    ])
    func encode_matchesRFC4648Vectors(_ input: String, _ expected: String) {
        #expect(Base64.encode(Array(input.utf8)) == expected)
    }

    @Test
    func encode_usesStandardAlphabetWithPlusAndSlash() {
        #expect(Base64.encode([0xfb, 0xff, 0xbf]) == "+/+/")
    }

    @Test
    func encode_thenDecode_roundTripsArbitraryBytes() throws {
        let bytes: [UInt8] = (0...255).map { UInt8($0) }
        let decoded = try Base64.decode(Base64.encode(bytes))
        #expect(decoded == bytes)
    }
}
