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

package enum Crc16 {

    @inline(__always)
    package static func ccittXmodem(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            let index = Int(truncatingIfNeeded: (crc >> 8) ^ UInt16(byte))
            crc = (crc &<< 8) ^ table[index]
        }
        return crc
    }

    @inline(__always)
    package static func ccittXmodem(_ bytes: [UInt8]) -> UInt16 {
        ccittXmodem(bytes[bytes.indices])
    }

    package static let table: [UInt16] = {
        var values = [UInt16](repeating: 0, count: 256)
        for index in 0..<256 {
            values[index] = ccittTableEntry(forIndex: index)
        }
        return values
    }()

    private static func ccittTableEntry(forIndex index: Int) -> UInt16 {
        var crc = UInt16(index) &<< 8
        for _ in 0..<8 {
            crc = ccittShift(crc)
        }
        return crc
    }

    @inline(__always)
    private static func ccittShift(_ crc: UInt16) -> UInt16 {
        let topBitSet = (crc & 0x8000) != 0
        return topBitSet ? (crc &<< 1) ^ 0x1021 : (crc &<< 1)
    }
}
