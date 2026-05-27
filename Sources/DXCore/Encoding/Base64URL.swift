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

package enum Base64URL {

    package static let standardAlphabet: [UInt8] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    package static func encode(_ bytes: [UInt8]) -> String {
        var output: [UInt8] = []
        output.reserveCapacity((bytes.count * 4 + 2) / 3)
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
        if remaining == 2 {
            appendAlphabet(of: combined >> 6, into: &output)
        }
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
}
