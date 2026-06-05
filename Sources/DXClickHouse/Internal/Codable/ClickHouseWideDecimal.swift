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

// Renders the 256-bit limb representation shared by ClickHouseDecimal,
// ClickHouseInt256, and ClickHouseUInt256 into its exact decimal digit
// string by long division, so values past Int64 / Foundation.Decimal range
// round-trip losslessly. The limbs are four little-endian UInt64 words,
// limb0 least significant.
enum ClickHouseWideDecimal {

    static func unsignedDigits(_ limbs: (UInt64, UInt64, UInt64, UInt64)) -> String {
        var working = [limbs.3, limbs.2, limbs.1, limbs.0]
        var digits: [UInt8] = []
        repeat {
            digits.append(divideByTenInPlace(&working) + 0x30)
        } while working.contains(where: { $0 != 0 })
        return String(decoding: digits.reversed(), as: UTF8.self)
    }

    // Splits a signed 256-bit value into its sign and the decimal digits of
    // its magnitude, so callers can place a decimal point (ClickHouseDecimal)
    // or a leading minus (ClickHouseInt256) around the same digit string.
    static func signedDigits(_ limbs: (UInt64, UInt64, UInt64, UInt64)) -> (negative: Bool, digits: String) {
        let negative = limbs.3 & 0x8000_0000_0000_0000 != 0
        let magnitude = negative ? negated(limbs) : limbs
        return (negative, unsignedDigits(magnitude))
    }

    // Parses an unsigned decimal digit string (ASCII 0-9 only, validated by
    // the caller) into 256-bit limbs, applying two's-complement negation when
    // `negative`. The inverse of signedDigits. Throws when the magnitude
    // exceeds 256 bits. limb0 is least significant.
    static func limbs(fromMagnitudeDigits digits: Substring, negative: Bool) throws(ClickHouseError) -> (UInt64, UInt64, UInt64, UInt64) {
        let magnitude = try parseMagnitude(digits)
        return negative ? negated(magnitude) : magnitude
    }

    private static func parseMagnitude(_ digits: Substring) throws(ClickHouseError) -> (UInt64, UInt64, UInt64, UInt64) {
        var limbs: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
        for ascii in digits.utf8 {
            guard multiplyByTenAddDigit(&limbs, digit: UInt64(ascii &- 0x30)) else {
                throw .protocolError(stage: "decimal", message: "value exceeds the 256-bit Decimal256 range")
            }
        }
        return limbs
    }

    private static func multiplyByTenAddDigit(_ limbs: inout (UInt64, UInt64, UInt64, UInt64), digit: UInt64) -> Bool {
        var words = [limbs.0, limbs.1, limbs.2, limbs.3]
        var carry = digit
        for index in words.indices {
            let product = UInt128(words[index]) * 10 + UInt128(carry)
            words[index] = UInt64(truncatingIfNeeded: product)
            carry = UInt64(product >> 64)
        }
        guard carry == 0 else { return false }
        limbs = (words[0], words[1], words[2], words[3])
        return true
    }

    private static func negated(_ limbs: (UInt64, UInt64, UInt64, UInt64)) -> (UInt64, UInt64, UInt64, UInt64) {
        var inverted = [~limbs.0, ~limbs.1, ~limbs.2, ~limbs.3]
        var carry: UInt64 = 1
        for index in inverted.indices {
            let (sum, overflow) = inverted[index].addingReportingOverflow(carry)
            inverted[index] = sum
            carry = overflow ? 1 : 0
        }
        return (inverted[0], inverted[1], inverted[2], inverted[3])
    }

    private static func divideByTenInPlace(_ working: inout [UInt64]) -> UInt8 {
        var remainder: UInt128 = 0
        for index in working.indices {
            let accumulator = remainder << 64 | UInt128(working[index])
            working[index] = UInt64(accumulator / 10)
            remainder = accumulator % 10
        }
        return UInt8(remainder)
    }
}
