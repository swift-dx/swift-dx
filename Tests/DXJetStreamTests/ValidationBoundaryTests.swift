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
@testable import DXJetStream

@Suite
struct ValidationBoundaryTests {

    private let alphaBytes: [UInt8] = Array(0x41...0x5a) + Array(0x61...0x7a)
    private let digitBytes: [UInt8] = Array(0x30...0x39)
    private let nameSpecials: [UInt8] = [0x2d, 0x5f]
    private let subjectSpecials: [UInt8] = [0x2d, 0x5f, 0x2a, 0x3e, 0x24]

    @Test
    func streamName_acceptsEveryAlphanumericAndHyphenUnderscore() throws {
        for byte in alphaBytes + digitBytes + nameSpecials {
            let value = String(decoding: [byte], as: UTF8.self)
            _ = try StreamName(value)
        }
    }

    @Test
    func streamName_rejectsEveryByteOutsideAllowedSet() {
        let allowed = Set(alphaBytes + digitBytes + nameSpecials)
        for byte in (0x20...0x7e).map(UInt8.init) where !allowed.contains(byte) {
            let value = String(decoding: [byte], as: UTF8.self)
            #expect(throws: JetStreamError.self) {
                _ = try StreamName(value)
            }
        }
    }

    @Test
    func consumerName_acceptsEveryAlphanumericAndHyphenUnderscore() throws {
        for byte in alphaBytes + digitBytes + nameSpecials {
            let value = String(decoding: [byte], as: UTF8.self)
            _ = try ConsumerName(value)
        }
    }

    @Test
    func consumerName_rejectsEveryByteOutsideAllowedSet() {
        let allowed = Set(alphaBytes + digitBytes + nameSpecials)
        for byte in (0x20...0x7e).map(UInt8.init) where !allowed.contains(byte) {
            let value = String(decoding: [byte], as: UTF8.self)
            #expect(throws: JetStreamError.self) {
                _ = try ConsumerName(value)
            }
        }
    }

    @Test
    func subject_acceptsEveryAlphanumericPlusSpecialAllowedByte() throws {
        for byte in alphaBytes + digitBytes + subjectSpecials {
            let value = String(decoding: [byte], as: UTF8.self)
            _ = try Subject(value)
        }
    }

    @Test
    func subject_rejectsEveryPrintableByteOutsideAllowedSet() {
        let allowed = Set(alphaBytes + digitBytes + subjectSpecials + [0x2e])
        for byte in (0x21...0x7e).map(UInt8.init) where !allowed.contains(byte) {
            let value = String(decoding: [byte], as: UTF8.self)
            #expect(throws: JetStreamError.self) {
                _ = try Subject(value)
            }
        }
    }

    @Test
    func subject_acceptsLongValue() throws {
        let value = String(repeating: "a", count: 4096)
        _ = try Subject(value)
    }
}
