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

// A value destined for a ClickHouse BFloat16 column (ClickHouse 24.11+).
// Brain Floating Point is a 16-bit float with the same 8-bit exponent as
// Float32 and a 7-bit mantissa: the raw pattern is the top 16 bits of a
// Float32 representation.
//
// Encoding to the wire pattern rounds the discarded low 16 bits to nearest,
// ties to even, so the stored value is the closest BFloat16 to the input
// rather than a plain truncation. Decoding zero-extends the 16-bit pattern
// back into the upper half of a Float32 pattern, which is exact.
public struct ClickHouseBFloat16: Sendable, Hashable, Codable {

    public let float: Float

    public init(float: Float) {
        self.float = float
    }

    public init(rawBits: UInt16) {
        self.float = Float(bitPattern: UInt32(rawBits) << 16)
    }

    public var rawBits: UInt16 {
        Self.roundToBFloat16(float.bitPattern)
    }

    static func roundToBFloat16(_ bits: UInt32) -> UInt16 {
        let exponentAndMantissa = bits & 0x7FFF_FFFF
        if exponentAndMantissa > 0x7F80_0000 {
            return UInt16(truncatingIfNeeded: (bits >> 16) | 0x0040)
        }
        let roundingBias = 0x7FFF &+ ((bits >> 16) & 1)
        return UInt16(truncatingIfNeeded: (bits &+ roundingBias) >> 16)
    }
}
