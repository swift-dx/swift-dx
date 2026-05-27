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

package enum Base32Error: Error, Sendable, Equatable {

    case invalidCharacter
}

package enum Base32 {

    package static let alphabet: [UInt8] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    private static let sentinelInvalid: UInt8 = 0xff
    private static let sentinelSkip: UInt8 = 0xfe

    package static let decodeTable: [UInt8] = {
        var table = [UInt8](repeating: sentinelInvalid, count: 256)
        for index in 0..<26 {
            table[0x41 &+ index] = UInt8(truncatingIfNeeded: index)
            table[0x61 &+ index] = UInt8(truncatingIfNeeded: index)
        }
        for index in 0..<6 {
            table[0x32 &+ index] = UInt8(truncatingIfNeeded: 26 &+ index)
        }
        table[0x3d] = sentinelSkip
        return table
    }()

    package static func decode(_ encoded: String) throws(Base32Error) -> [UInt8] {
        try decode(Array(encoded.utf8))
    }

    package static func decode(_ encoded: [UInt8]) throws(Base32Error) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity((encoded.count * 5) / 8)
        var buffer: UInt32 = 0
        var bitsInBuffer: Int = 0
        for byte in encoded {
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
    ) throws(Base32Error) {
        let mapped = decodeTable[Int(truncatingIfNeeded: byte)]
        if mapped == sentinelSkip { return }
        if mapped == sentinelInvalid { throw Base32Error.invalidCharacter }
        buffer = (buffer &<< 5) | UInt32(mapped)
        bitsInBuffer &+= 5
        flushOutputByteIfReady(buffer: &buffer, bitsInBuffer: &bitsInBuffer, output: &output)
    }

    @inline(__always)
    private static func flushOutputByteIfReady(
        buffer: inout UInt32,
        bitsInBuffer: inout Int,
        output: inout [UInt8]
    ) {
        guard bitsInBuffer >= 8 else { return }
        bitsInBuffer &-= 8
        let outByte = UInt8(truncatingIfNeeded: buffer >> UInt32(bitsInBuffer))
        output.append(outByte)
        buffer &= (1 << UInt32(bitsInBuffer)) &- 1
    }
}
