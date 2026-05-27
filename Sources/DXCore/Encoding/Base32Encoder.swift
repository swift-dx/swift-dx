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

package enum Base32Encoder {

    package static func encode(_ bytes: [UInt8]) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(((bytes.count * 8) + 4) / 5)
        var buffer: UInt32 = 0
        var bitsInBuffer = 0
        for byte in bytes {
            absorbByte(byte, buffer: &buffer, bitsInBuffer: &bitsInBuffer, output: &output)
        }
        appendTrailingChunk(buffer: buffer, bitsInBuffer: bitsInBuffer, output: &output)
        return String(decoding: output, as: UTF8.self)
    }

    @inline(__always)
    private static func absorbByte(
        _ byte: UInt8,
        buffer: inout UInt32,
        bitsInBuffer: inout Int,
        output: inout [UInt8]
    ) {
        buffer = (buffer << 8) | UInt32(byte)
        bitsInBuffer += 8
        while bitsInBuffer >= 5 {
            emitChunk(buffer: &buffer, bitsInBuffer: &bitsInBuffer, output: &output)
        }
    }

    @inline(__always)
    private static func emitChunk(
        buffer: inout UInt32,
        bitsInBuffer: inout Int,
        output: inout [UInt8]
    ) {
        bitsInBuffer -= 5
        let value = Int((buffer >> UInt32(bitsInBuffer)) & 0x1f)
        output.append(Base32.alphabet[value])
        buffer &= (1 << UInt32(bitsInBuffer)) - 1
    }

    @inline(__always)
    private static func appendTrailingChunk(
        buffer: UInt32,
        bitsInBuffer: Int,
        output: inout [UInt8]
    ) {
        guard bitsInBuffer > 0 else { return }
        let value = Int((buffer << UInt32(5 - bitsInBuffer)) & 0x1f)
        output.append(Base32.alphabet[value])
    }
}
