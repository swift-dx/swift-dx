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
struct HexIdGeneratorTests {

    @Test
    func defaultByteCountProducesTwentyFourHexChars() {
        let id = HexIdGenerator.newLowerHexString()
        #expect(id.count == 24)
    }

    @Test
    func customByteCountProducesMatchingHexLength() {
        let id = HexIdGenerator.newLowerHexString(byteCount: 8)
        #expect(id.count == 16)
    }

    @Test
    func outputContainsOnlyLowercaseHexDigits() {
        let id = HexIdGenerator.newLowerHexString(byteCount: 32)
        let validHex: Set<Character> = Set("0123456789abcdef")
        for character in id {
            #expect(validHex.contains(character))
        }
    }

    @Test
    func successiveCallsProduceDifferentValues() {
        let first = HexIdGenerator.newLowerHexString(byteCount: 16)
        let second = HexIdGenerator.newLowerHexString(byteCount: 16)
        #expect(first != second)
    }

    @Test
    func zeroByteCountProducesEmptyString() {
        let id = HexIdGenerator.newLowerHexString(byteCount: 0)
        #expect(id.isEmpty)
    }
}
