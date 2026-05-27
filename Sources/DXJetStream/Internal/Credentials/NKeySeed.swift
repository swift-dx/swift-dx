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

import DXCore

struct NKeySeed: Sendable {

    let rawSeed: [UInt8]

    init(rawSeed: [UInt8]) {
        self.rawSeed = rawSeed
    }

    static func decode(_ encoded: String) throws(JetStreamError) -> NKeySeed {
        guard !encoded.isEmpty else {
            throw JetStreamError.credentialsSeedInvalid(reason: "empty seed string")
        }
        let decoded = try decodeBase32Payload(encoded)
        return try buildSeed(fromDecoded: decoded)
    }

    private static func decodeBase32Payload(_ encoded: String) throws(JetStreamError) -> [UInt8] {
        do {
            return try Base32.decode(encoded)
        } catch {
            throw JetStreamError.credentialsSeedInvalid(reason: "seed is not valid base32")
        }
    }

    private static func buildSeed(fromDecoded decoded: [UInt8]) throws(JetStreamError) -> NKeySeed {
        try validateDecodedLength(decoded)
        try validatePrefixBytes(decoded)
        try validateChecksum(decoded)
        return NKeySeed(rawSeed: Array(decoded[NKeyEncoding.seedStartIndex..<NKeyEncoding.seedEndIndex]))
    }

    private static func validateDecodedLength(_ decoded: [UInt8]) throws(JetStreamError) {
        guard decoded.count == NKeyEncoding.totalByteCount else {
            throw JetStreamError.credentialsSeedInvalid(reason: "decoded seed must be \(NKeyEncoding.totalByteCount) bytes, got \(decoded.count)")
        }
    }

    private static func validatePrefixBytes(_ decoded: [UInt8]) throws(JetStreamError) {
        try validateSeedPrefix(decoded)
        try validateSubjectPrefix(decoded)
    }

    private static func validateSeedPrefix(_ decoded: [UInt8]) throws(JetStreamError) {
        let seedPrefix = decoded[NKeyEncoding.prefixByte0Index] & NKeyEncoding.seedPrefixMask
        guard seedPrefix == NKeyPrefix.seed.rawValue else {
            throw JetStreamError.credentialsSeedInvalid(reason: "seed must start with the S prefix byte")
        }
    }

    private static func validateSubjectPrefix(_ decoded: [UInt8]) throws(JetStreamError) {
        let highBits = (decoded[NKeyEncoding.prefixByte0Index] & NKeyEncoding.subjectPrefixHighMask) << NKeyEncoding.subjectPrefixHighShift
        let lowBits = decoded[NKeyEncoding.prefixByte1Index] >> NKeyEncoding.subjectPrefixLowShift
        let subjectPrefix = highBits | lowBits
        guard subjectPrefix == NKeyPrefix.user.rawValue else {
            throw JetStreamError.credentialsSeedInvalid(reason: "only user seeds (SU...) are supported")
        }
    }

    private static func validateChecksum(_ decoded: [UInt8]) throws(JetStreamError) {
        let payload = Array(decoded[0..<NKeyEncoding.payloadByteCount])
        let lowByte = UInt16(decoded[NKeyEncoding.checksumLowByteIndex])
        let highByte = UInt16(decoded[NKeyEncoding.checksumHighByteIndex])
        let storedChecksum = (highByte << NKeyEncoding.checksumByteShift) | lowByte
        let computedChecksum = Crc16.ccittXmodem(payload[payload.indices])
        guard storedChecksum == computedChecksum else {
            throw JetStreamError.credentialsSeedInvalid(reason: "checksum mismatch (stored=\(String(storedChecksum, radix: 16)) computed=\(String(computedChecksum, radix: 16)))")
        }
    }

    static func encode(rawSeed: [UInt8], publicPrefix: NKeyPrefix = .user) throws(JetStreamError) -> String {
        guard rawSeed.count == NKeyEncoding.seedByteCount else {
            throw JetStreamError.credentialsSeedInvalid(reason: "raw seed must be \(NKeyEncoding.seedByteCount) bytes, got \(rawSeed.count)")
        }
        let payload = buildPayload(rawSeed: rawSeed, publicPrefix: publicPrefix)
        let checksum = Crc16.ccittXmodem(payload[payload.indices])
        let combined = appendChecksum(to: payload, checksum: checksum)
        return Base32Encoder.encode(combined)
    }

    private static func buildPayload(rawSeed: [UInt8], publicPrefix: NKeyPrefix) -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: NKeyEncoding.payloadByteCount)
        payload[NKeyEncoding.prefixByte0Index] = NKeyPrefix.seed.rawValue | (publicPrefix.rawValue >> NKeyEncoding.subjectPrefixHighShift)
        payload[NKeyEncoding.prefixByte1Index] = (publicPrefix.rawValue & NKeyEncoding.subjectPrefixLowMask) << NKeyEncoding.subjectPrefixLowShift
        for byteIndex in 0..<NKeyEncoding.seedByteCount {
            payload[NKeyEncoding.seedStartIndex + byteIndex] = rawSeed[byteIndex]
        }
        return payload
    }

    private static func appendChecksum(to payload: [UInt8], checksum: UInt16) -> [UInt8] {
        var combined = payload
        combined.append(UInt8(truncatingIfNeeded: checksum))
        combined.append(UInt8(truncatingIfNeeded: checksum >> NKeyEncoding.checksumByteShift))
        return combined
    }
}
