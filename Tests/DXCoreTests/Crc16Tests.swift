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
struct Crc16Tests {

    @Test
    func crc16_emptyInputIsZero() {
        #expect(Crc16.ccittXmodem([]) == 0x0000)
    }

    @Test
    func crc16_singleByteMatchesXmodemReference() {
        #expect(Crc16.ccittXmodem([0x00]) == 0x0000)
        #expect(Crc16.ccittXmodem([0x01]) == 0x1021)
        #expect(Crc16.ccittXmodem([0xff]) == 0x1ef0)
    }

    @Test
    func crc16_asciiInputMatchesXmodemReference() {
        #expect(Crc16.ccittXmodem(Array("123456789".utf8)) == 0x31c3)
    }

    @Test
    func crc16_isDeterministic() {
        let bytes: [UInt8] = [0x10, 0x20, 0x30, 0x40, 0x50]
        let first = Crc16.ccittXmodem(bytes)
        let second = Crc16.ccittXmodem(bytes)
        #expect(first == second)
    }
}
