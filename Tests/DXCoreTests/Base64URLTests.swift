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
struct Base64URLTests {

    @Test
    func base64URL_encodesEmpty() {
        #expect(Base64URL.encode([]) == "")
    }

    @Test
    func base64URL_encodesSingleByte() {
        #expect(Base64URL.encode([0x66]) == "Zg")
    }

    @Test
    func base64URL_encodesTwoBytes() {
        #expect(Base64URL.encode([0x66, 0x6f]) == "Zm8")
    }

    @Test
    func base64URL_encodesThreeBytes() {
        #expect(Base64URL.encode([0x66, 0x6f, 0x6f]) == "Zm9v")
    }

    @Test
    func base64URL_replacesPlusAndSlash() {
        let bytes: [UInt8] = [0xff, 0xff, 0xff]
        let encoded = Base64URL.encode(bytes)
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
    }

    @Test
    func base64URL_roundTripsRandomBytes() throws {
        let bytes: [UInt8] = (0..<64).map { UInt8($0) }
        let encoded = Base64URL.encode(bytes)
        let decoded = try Base64.decode(encoded)
        #expect(decoded == bytes)
    }
}
