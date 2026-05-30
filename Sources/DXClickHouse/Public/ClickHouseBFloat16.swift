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

// Brain Floating Point (BFloat16): 16-bit IEEE-754 variant used in
// ML/AI workloads. Layout: 1 sign bit + 8 exponent bits + 7 mantissa
// bits (vs Float32's 1+8+23). Same exponent range as Float32, just a
// truncated mantissa.
//
// The raw 16-bit pattern is exactly the upper half of Float32's
// IEEE-754 representation, so conversion in both directions is just
// a bit-pattern shift:
//   - BFloat16 → Float32: zero-extend (lossless within BFloat16's
//     representable range)
//   - Float32 → BFloat16: truncate lower 16 mantissa bits (lossy;
//     about 2-3 decimal digits of precision)
//
// NaN, ±Infinity, and ±Zero work cleanly since BFloat16 inherits the
// exponent encoding from Float32. Subnormals lose precision but stay
// representable.
public struct ClickHouseBFloat16: Sendable, Equatable, Hashable {

    public let rawBits: UInt16

    public init(rawBits: UInt16) {
        self.rawBits = rawBits
    }

    public init(_ value: Float) {
        // Truncate the lower 16 bits of Float32's bit pattern. For NaN
        // values this preserves the sign bit and the leading mantissa
        // bits but may quiet a signaling NaN — typical for narrowing
        // float conversions.
        let upper = value.bitPattern >> 16
        self.rawBits = UInt16(truncatingIfNeeded: upper)
    }

    public var floatValue: Float {
        // Zero-extend by shifting the raw 16 bits to the upper half of
        // a 32-bit pattern, then reinterpret as Float32.
        let bitPattern = UInt32(rawBits) << 16
        return Float(bitPattern: bitPattern)
    }

    public static let zero = Self(rawBits: 0)

}
