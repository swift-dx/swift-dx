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
struct NKeySeedTests {

    @Test
    func nkeySeed_roundTripsRandomSeed() throws {
        let rawSeed = TestFixtures.randomSeedBytes()
        let encoded = try NKeySeed.encode(rawSeed: rawSeed)
        let decoded = try NKeySeed.decode(encoded)
        #expect(decoded.rawSeed == rawSeed)
    }

    @Test
    func nkeySeed_decodesEncodedSeedToOriginalBytes() throws {
        let original: [UInt8] = (0..<32).map { UInt8($0) }
        let encoded = try NKeySeed.encode(rawSeed: original)
        let decoded = try NKeySeed.decode(encoded)
        #expect(decoded.rawSeed == original)
    }

    @Test
    func nkeySeed_encodedSeedStartsWithSU() throws {
        let rawSeed: [UInt8] = (0..<32).map { _ in 0 }
        let encoded = try NKeySeed.encode(rawSeed: rawSeed)
        #expect(encoded.hasPrefix("SU"))
    }

    @Test
    func nkeySeed_encodedSeedIsFiftyEightCharacters() throws {
        let rawSeed: [UInt8] = (0..<32).map { _ in 0 }
        let encoded = try NKeySeed.encode(rawSeed: rawSeed)
        #expect(encoded.count == 58)
    }

    @Test
    func nkeySeed_throwsOnEmpty() {
        #expect(throws: JetStreamError.self) {
            _ = try NKeySeed.decode("")
        }
    }

    @Test
    func nkeySeed_throwsOnNonBase32() {
        #expect(throws: JetStreamError.self) {
            _ = try NKeySeed.decode("not-base32!!!")
        }
    }

    @Test
    func nkeySeed_throwsOnWrongLength() {
        #expect(throws: JetStreamError.self) {
            _ = try NKeySeed.decode("MZXW6")
        }
    }

    @Test
    func nkeySeed_throwsOnCorruptedChecksum() throws {
        let rawSeed: [UInt8] = (0..<32).map { UInt8($0) }
        var encoded = try NKeySeed.encode(rawSeed: rawSeed)
        encoded.removeLast()
        encoded.append("A")
        #expect(throws: JetStreamError.self) {
            _ = try NKeySeed.decode(encoded)
        }
    }

    @Test
    func nkeySeed_encodeRejectsWrongLengthRawSeed() {
        #expect(throws: JetStreamError.self) {
            _ = try NKeySeed.encode(rawSeed: [0, 1, 2])
        }
    }
}
