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
