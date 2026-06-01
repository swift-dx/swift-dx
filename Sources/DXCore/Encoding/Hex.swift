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

package enum HexError: Error, Sendable, Equatable {

    case oddLength
    case invalidCharacter
}

package enum Hex {

    package static let lowercaseAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

    package static func encodeLower(_ bytes: [UInt8]) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            appendNibbles(of: byte, into: &output)
        }
        return String(decoding: output, as: UTF8.self)
    }

    @inline(__always)
    private static func appendNibbles(of byte: UInt8, into output: inout [UInt8]) {
        output.append(lowercaseAlphabet[Int(byte >> 4)])
        output.append(lowercaseAlphabet[Int(byte & 0x0f)])
    }

    package static func decode(_ text: String) throws(HexError) -> [UInt8] {
        let bytes = Array(text.utf8)
        guard bytes.count % 2 == 0 else { throw HexError.oddLength }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count / 2)
        var index = 0
        while index < bytes.count {
            let high = try nibble(bytes[index])
            let low = try nibble(bytes[index + 1])
            output.append((high << 4) | low)
            index += 2
        }
        return output
    }

    private static func nibble(_ byte: UInt8) throws(HexError) -> UInt8 {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        default: return try letterNibble(byte)
        }
    }

    private static func letterNibble(_ byte: UInt8) throws(HexError) -> UInt8 {
        switch byte {
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: throw HexError.invalidCharacter
        }
    }
}
