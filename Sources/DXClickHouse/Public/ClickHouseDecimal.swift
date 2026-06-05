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

// A value destined for a ClickHouse Decimal column. The stored magnitude is
// the signed unscaled integer (the represented value is `magnitude /
// 10^scale`). The unscaled integer is held as four little-endian UInt64
// limbs, limb0 least significant, sign-extended across unused limbs. The
// wire form writes `byteWidth` little-endian bytes per row, where the width
// is selected from the declared precision: P<=9 -> 4 (Int32), P<=18 -> 8
// (Int64), P<=38 -> 16 (Int128), P<=76 -> 32 (four limbs).
public struct ClickHouseDecimal: Sendable, Hashable, Codable {

    public let limb0: UInt64
    public let limb1: UInt64
    public let limb2: UInt64
    public let limb3: UInt64
    public let precision: UInt8
    public let scale: UInt8

    public init(limb0: UInt64, limb1: UInt64, limb2: UInt64, limb3: UInt64, precision: UInt8, scale: UInt8) {
        self.limb0 = limb0
        self.limb1 = limb1
        self.limb2 = limb2
        self.limb3 = limb3
        self.precision = precision
        self.scale = scale
    }

    // The wire form: the low `width` little-endian bytes (width selected by
    // precision) of the signed limbs. Inverse of init(littleEndianBytes:).
    package var littleEndianBytes: [UInt8] {
        let width = ClickHouseDecimalWidth.bytes(forPrecision: precision)
        let leLimbs = (limb0.littleEndian, limb1.littleEndian, limb2.littleEndian, limb3.littleEndian)
        var out = [UInt8](repeating: 0, count: width)
        withUnsafeBytes(of: leLimbs) { source in
            for index in 0..<width {
                out[index] = source[index]
            }
        }
        return out
    }

    // Builds the value from the wire form: `width` little-endian bytes
    // (width selected by precision), sign-extended across the unused high
    // limbs. The caller supplies exactly the column's element width.
    package init(littleEndianBytes bytes: [UInt8], precision: UInt8, scale: UInt8) {
        let width = ClickHouseDecimalWidth.bytes(forPrecision: precision)
        let fill: UInt64 = (bytes[width - 1] & 0x80) != 0 ? .max : 0
        var limbs: (UInt64, UInt64, UInt64, UInt64) = (fill, fill, fill, fill)
        withUnsafeMutableBytes(of: &limbs) { destination in
            for index in 0..<width {
                destination[index] = bytes[index]
            }
        }
        self.init(
            limb0: UInt64(littleEndian: limbs.0),
            limb1: UInt64(littleEndian: limbs.1),
            limb2: UInt64(littleEndian: limbs.2),
            limb3: UInt64(littleEndian: limbs.3),
            precision: precision,
            scale: scale
        )
    }

    public init(unscaled: Int64, precision: UInt8, scale: UInt8) {
        let extension64: UInt64 = unscaled < 0 ? .max : 0
        self.init(
            limb0: UInt64(bitPattern: unscaled),
            limb1: extension64,
            limb2: extension64,
            limb3: extension64,
            precision: precision,
            scale: scale
        )
    }

    // Parses fixed-point decimal text (e.g. "1234.56") into the unscaled
    // value at the given scale and round-trips with `description`. A fraction
    // shorter than `scale` is right-padded; one longer is rejected (no silent
    // rounding). Supports every width: the magnitude is parsed into 256-bit
    // limbs, so Decimal128 and Decimal256 values that exceed Int64 are
    // accepted. A value whose significant-digit count exceeds the precision is
    // rejected, since it would not fit the column's element width and would
    // silently truncate on the wire.
    public init(_ text: String, precision: UInt8, scale: UInt8) throws(ClickHouseError) {
        let signed = Self.signedBody(text)
        let split = try Self.splitDecimalPoint(signed.body, source: text)
        let combined = try Self.scaledDigitString(integer: split.integer, fraction: split.fraction, scale: Int(scale), source: text)
        guard Self.significantDigitCount(combined) <= Int(precision) else {
            throw Self.invalidDecimal(text, "value has more significant digits than the precision \(precision)")
        }
        let limbs = try ClickHouseWideDecimal.limbs(fromMagnitudeDigits: Substring(combined), negative: signed.negative)
        self.init(limb0: limbs.0, limb1: limbs.1, limb2: limbs.2, limb3: limbs.3, precision: precision, scale: scale)
    }

    private static func significantDigitCount(_ digits: String) -> Int {
        digits.drop(while: { $0 == "0" }).count
    }

    private static func signedBody(_ text: String) -> (negative: Bool, body: Substring) {
        let body = Substring(text)
        if body.first == "-" { return (true, body.dropFirst()) }
        if body.first == "+" { return (false, body.dropFirst()) }
        return (false, body)
    }

    private static func splitDecimalPoint(_ body: Substring, source: String) throws(ClickHouseError) -> (integer: Substring, fraction: Substring) {
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 1 { return (parts[0], "") }
        guard parts.count == 2 else { throw invalidDecimal(source, "more than one decimal point") }
        return (parts[0], parts[1])
    }

    private static func scaledDigitString(integer: Substring, fraction: Substring, scale: Int, source: String) throws(ClickHouseError) -> String {
        guard integer.count + fraction.count > 0 else { throw invalidDecimal(source, "no digits") }
        guard fraction.count <= scale else { throw invalidDecimal(source, "fraction has more than \(scale) digits (the column scale)") }
        try requireDigits(integer, source: source)
        try requireDigits(fraction, source: source)
        return String(integer) + String(fraction) + String(repeating: "0", count: scale - fraction.count)
    }

    private static func requireDigits(_ text: Substring, source: String) throws(ClickHouseError) {
        for character in text where !character.isNumber {
            throw invalidDecimal(source, "contains a non-digit character")
        }
    }

    private static func invalidDecimal(_ text: String, _ reason: String) -> ClickHouseError {
        .protocolError(stage: "decimal", message: "'\(text)' is not a valid fixed-point decimal: \(reason)")
    }
}
