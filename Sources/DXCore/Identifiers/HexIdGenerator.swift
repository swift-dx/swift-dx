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

package enum HexIdGenerator {

    package static func newLowerHexString(byteCount: Int = 12) -> String {
        let bytes = generateRandomBytes(count: byteCount)
        return encodeLowerHex(bytes)
    }

    private static func generateRandomBytes(count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        while bytes.count < count {
            let chunk = UInt32.random(in: .min ... .max, using: &generator)
            appendByte(chunk: chunk, shift: 24, into: &bytes, limit: count)
            appendByte(chunk: chunk, shift: 16, into: &bytes, limit: count)
            appendByte(chunk: chunk, shift: 8, into: &bytes, limit: count)
            appendByte(chunk: chunk, shift: 0, into: &bytes, limit: count)
        }
        return bytes
    }

    @inline(__always)
    private static func appendByte(chunk: UInt32, shift: Int, into bytes: inout [UInt8], limit: Int) {
        guard bytes.count < limit else { return }
        bytes.append(UInt8((chunk >> shift) & 0xff))
    }

    private static func encodeLowerHex(_ bytes: [UInt8]) -> String {
        var output = ""
        output.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            output.append(hexDigit(byte >> 4))
            output.append(hexDigit(byte & 0x0f))
        }
        return output
    }

    private static func hexDigit(_ nibble: UInt8) -> Character {
        if nibble < 10 {
            return Character(Unicode.Scalar(UInt8(0x30) &+ nibble))
        }
        return Character(Unicode.Scalar(UInt8(0x61) &+ (nibble &- 10)))
    }
}
