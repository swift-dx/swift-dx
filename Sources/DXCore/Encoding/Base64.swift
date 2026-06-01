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

package enum Base64Error: Error, Sendable, Equatable {

    case invalidCharacter
}

package enum Base64 {

    package static let standardAlphabet: [UInt8] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
    package static let padding: UInt8 = 0x3d

    package static func encode(_ bytes: [UInt8]) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(((bytes.count + 2) / 3) * 4)
        var index = 0
        while index + 3 <= bytes.count {
            appendFullTriplet(bytes: bytes, startIndex: index, output: &output)
            index += 3
        }
        appendTrailingTriplet(bytes: bytes, startIndex: index, output: &output)
        return String(decoding: output, as: UTF8.self)
    }

    @inline(__always)
    private static func appendFullTriplet(bytes: [UInt8], startIndex: Int, output: inout [UInt8]) {
        let combined = packTriplet(bytes: bytes, startIndex: startIndex, count: 3)
        appendAlphabet(of: combined >> 18, into: &output)
        appendAlphabet(of: combined >> 12, into: &output)
        appendAlphabet(of: combined >> 6, into: &output)
        appendAlphabet(of: combined, into: &output)
    }

    @inline(__always)
    private static func appendTrailingTriplet(bytes: [UInt8], startIndex: Int, output: inout [UInt8]) {
        let remaining = bytes.count - startIndex
        guard remaining > 0 else { return }
        let combined = packTriplet(bytes: bytes, startIndex: startIndex, count: remaining)
        appendAlphabet(of: combined >> 18, into: &output)
        appendAlphabet(of: combined >> 12, into: &output)
        appendThirdEncodedByte(remaining: remaining, combined: combined, output: &output)
        output.append(padding)
    }

    @inline(__always)
    private static func appendThirdEncodedByte(remaining: Int, combined: UInt32, output: inout [UInt8]) {
        guard remaining == 2 else { output.append(padding); return }
        appendAlphabet(of: combined >> 6, into: &output)
    }

    @inline(__always)
    private static func packTriplet(bytes: [UInt8], startIndex: Int, count: Int) -> UInt32 {
        let b0 = UInt32(bytes[startIndex])
        let b1 = count >= 2 ? UInt32(bytes[startIndex + 1]) : 0
        let b2 = count >= 3 ? UInt32(bytes[startIndex + 2]) : 0
        return (b0 << 16) | (b1 << 8) | b2
    }

    @inline(__always)
    private static func appendAlphabet(of value: UInt32, into output: inout [UInt8]) {
        output.append(standardAlphabet[Int(value & 0x3f)])
    }

    package static func decode(_ encoded: String) throws(Base64Error) -> [UInt8] {
        let bytes = Array(encoded.utf8)
        var output: [UInt8] = []
        output.reserveCapacity((bytes.count * 3) / 4)
        var buffer: UInt32 = 0
        var bitsInBuffer: Int = 0
        for byte in bytes {
            try absorbByte(byte, buffer: &buffer, bitsInBuffer: &bitsInBuffer, output: &output)
        }
        return output
    }

    @inline(__always)
    private static func absorbByte(
        _ byte: UInt8,
        buffer: inout UInt32,
        bitsInBuffer: inout Int,
        output: inout [UInt8]
    ) throws(Base64Error) {
        let value: UInt32
        switch decodeByte(byte) {
        case .skip: return
        case .invalid: throw Base64Error.invalidCharacter
        case .value(let mapped): value = mapped
        }
        buffer = (buffer << 6) | value
        bitsInBuffer += 6
        flushOutputByteIfReady(buffer: &buffer, bitsInBuffer: &bitsInBuffer, output: &output)
    }

    @inline(__always)
    private static func decodeByte(_ byte: UInt8) -> ByteClassification {
        switch byte {
        case 0x41...0x5a: return .value(UInt32(byte - 0x41))
        case 0x61...0x7a: return .value(UInt32(byte - 0x61 + 26))
        case 0x30...0x39: return .value(UInt32(byte - 0x30 + 52))
        case 0x2b, 0x2d: return .value(62)
        case 0x2f, 0x5f: return .value(63)
        case 0x3d, 0x0a, 0x0d, 0x20, 0x09: return .skip
        default: return .invalid
        }
    }

    @inline(__always)
    private static func flushOutputByteIfReady(
        buffer: inout UInt32,
        bitsInBuffer: inout Int,
        output: inout [UInt8]
    ) {
        guard bitsInBuffer >= 8 else { return }
        bitsInBuffer -= 8
        let outByte = UInt8(truncatingIfNeeded: buffer >> UInt32(bitsInBuffer))
        output.append(outByte)
        buffer &= (1 << UInt32(bitsInBuffer)) - 1
    }

    private enum ByteClassification {

        case value(UInt32)
        case skip
        case invalid
    }
}
