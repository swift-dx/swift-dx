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

extension JSONReader {

    func encodeScalar(_ scalar: UInt32, into decoded: inout [UInt8]) {
        switch scalar {
        case 0 ..< 0x80: encodeOneByte(scalar, into: &decoded)
        case 0x80 ..< 0x800: encodeTwoBytes(scalar, into: &decoded)
        case 0x800 ..< 0x10000: encodeThreeBytes(scalar, into: &decoded)
        default: encodeFourBytes(scalar, into: &decoded)
        }
    }

    func encodeOneByte(_ scalar: UInt32, into decoded: inout [UInt8]) {
        decoded.append(UInt8(truncatingIfNeeded: scalar))
    }

    func encodeTwoBytes(_ scalar: UInt32, into decoded: inout [UInt8]) {
        decoded.append(UInt8(truncatingIfNeeded: 0xC0 | (scalar >> 6)))
        decoded.append(UInt8(truncatingIfNeeded: 0x80 | (scalar & 0x3F)))
    }

    func encodeThreeBytes(_ scalar: UInt32, into decoded: inout [UInt8]) {
        decoded.append(UInt8(truncatingIfNeeded: 0xE0 | (scalar >> 12)))
        decoded.append(UInt8(truncatingIfNeeded: 0x80 | ((scalar >> 6) & 0x3F)))
        decoded.append(UInt8(truncatingIfNeeded: 0x80 | (scalar & 0x3F)))
    }

    func encodeFourBytes(_ scalar: UInt32, into decoded: inout [UInt8]) {
        decoded.append(UInt8(truncatingIfNeeded: 0xF0 | (scalar >> 18)))
        decoded.append(UInt8(truncatingIfNeeded: 0x80 | ((scalar >> 12) & 0x3F)))
        decoded.append(UInt8(truncatingIfNeeded: 0x80 | ((scalar >> 6) & 0x3F)))
        decoded.append(UInt8(truncatingIfNeeded: 0x80 | (scalar & 0x3F)))
    }
}
