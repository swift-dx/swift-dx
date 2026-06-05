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

// A 256-bit value's wire form is its four UInt64 limbs in order, each
// little-endian (32 bytes, limb0 least significant). Shared so Int256 and
// UInt256 — and every decode/encode path that touches them — agree on the
// limb-to-byte mapping rather than each open-coding it.
enum ClickHouseWideIntegerWire {

    static func limbs(fromLittleEndianBytes bytes: [UInt8]) -> (UInt64, UInt64, UInt64, UInt64) {
        var limbs: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
        withUnsafeMutableBytes(of: &limbs) { destination in
            for index in 0..<32 {
                destination[index] = bytes[index]
            }
        }
        return (
            UInt64(littleEndian: limbs.0),
            UInt64(littleEndian: limbs.1),
            UInt64(littleEndian: limbs.2),
            UInt64(littleEndian: limbs.3)
        )
    }

    static func littleEndianBytes(limb0: UInt64, limb1: UInt64, limb2: UInt64, limb3: UInt64) -> [UInt8] {
        let little = (limb0.littleEndian, limb1.littleEndian, limb2.littleEndian, limb3.littleEndian)
        return withUnsafeBytes(of: little) { Array($0) }
    }
}
