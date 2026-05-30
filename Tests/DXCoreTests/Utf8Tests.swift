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
struct Utf8Tests {

    static let validSequences: [[UInt8]] = [
        [],
        Array("ascii".utf8),
        Array("héllo".utf8),
        Array("二維碼".utf8),
        Array("🎉".utf8),
        [0x24],
        [0xc2, 0xa2],
        [0xe2, 0x82, 0xac],
        [0xf0, 0x90, 0x8d, 0x88],
    ]

    static let invalidSequences: [[UInt8]] = [
        [0x80],
        [0xbf],
        [0xc2],
        [0xe2, 0x82],
        [0xf0, 0x90, 0x8d],
        [0xc0, 0x80],
        [0xed, 0xa0, 0x80],
        [0xf4, 0x90, 0x80, 0x80],
        [0xff],
        [0x41, 0x80, 0x42],
    ]

    @Test
    func acceptsValidUtf8() {
        for sequence in Self.validSequences {
            #expect(Utf8.isValid(sequence))
        }
    }

    @Test
    func rejectsInvalidUtf8() {
        for sequence in Self.invalidSequences {
            #expect(!Utf8.isValid(sequence))
        }
    }

    @Test
    func agreesWithStandardLibraryValidation() {
        for sequence in Self.validSequences + Self.invalidSequences {
            let standardLibraryAccepts = String(validating: sequence, as: UTF8.self) != nil
            #expect(Utf8.isValid(sequence) == standardLibraryAccepts)
        }
    }

    @Test
    func validatesArraySlice() {
        let buffer: [UInt8] = [0xff, 0x68, 0x69, 0xff]
        #expect(Utf8.isValid(buffer[1 ..< 3]))
        #expect(!Utf8.isValid(buffer[0 ..< 3]))
    }
}
