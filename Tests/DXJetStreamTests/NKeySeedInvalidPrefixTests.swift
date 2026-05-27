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
import DXCore
@testable import DXJetStream

@Suite
struct NKeySeedInvalidPrefixTests {

    @Test
    func decode_rejectsNonUserSubjectPrefix() throws {
        let bytes = TestFixtures.randomSeedBytes()
        let encodedAsAccount = try NKeySeed.encode(rawSeed: bytes, publicPrefix: .account)
        #expect(throws: JetStreamError.self) {
            _ = try NKeySeed.decode(encodedAsAccount)
        }
    }

    @Test
    func decode_rejectsSeedWithoutSeedPrefixBits() throws {
        var payload = [UInt8](repeating: 0, count: 30)
        payload[0] = 0x20
        payload[1] = 0x00
        for index in 2..<30 {
            payload[index] = UInt8(index)
        }
        let checksum = Crc16.ccittXmodem(payload[...])
        var combined = payload
        combined.append(UInt8(checksum & 0xFF))
        combined.append(UInt8((checksum >> 8) & 0xFF))
        let encoded = Base32Encoder.encode(combined)
        #expect(throws: JetStreamError.self) {
            _ = try NKeySeed.decode(encoded)
        }
    }
}
