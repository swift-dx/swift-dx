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

extension ClickHouseDecimal: CustomStringConvertible {

    // The stored limbs are a signed 256-bit two's-complement integer (the
    // unscaled value); the rendered value is that integer with a decimal
    // point placed `scale` digits from the right.
    public var description: String {
        let (negative, digits) = ClickHouseWideDecimal.signedDigits((limb0, limb1, limb2, limb3))
        let scaled = Self.applyScale(digits, scale: Int(scale))
        return negative ? "-" + scaled : scaled
    }

    private static func applyScale(_ digits: String, scale: Int) -> String {
        if scale == 0 {
            return digits
        }
        let padded = digits.count <= scale
            ? String(repeating: "0", count: scale - digits.count + 1) + digits
            : digits
        let splitIndex = padded.index(padded.endIndex, offsetBy: -scale)
        return String(padded[..<splitIndex]) + "." + String(padded[splitIndex...])
    }
}
