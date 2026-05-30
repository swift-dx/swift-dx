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

import DXCore

enum FormatScan {

    static func isDigit(_ byte: UInt8) -> Bool {
        if case .digit = ByteScan.decimalDigit(of: byte) { return true }
        return false
    }

    static func isHex(_ byte: UInt8) -> Bool {
        if isDigit(byte) { return true }
        return isHexLetter(byte)
    }

    static func isHexLetter(_ byte: UInt8) -> Bool {
        if byte >= Ascii.lowerA, byte <= Ascii.lowerF { return true }
        if byte >= Ascii.upperA, byte <= Ascii.upperF { return true }
        return false
    }

    static func allDigits(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard !bytes.isEmpty else { return false }
        return everyByte(bytes, satisfies: isDigit)
    }

    static func everyByte(_ bytes: ArraySlice<UInt8>, satisfies predicate: (UInt8) -> Bool) -> Bool {
        for byte in bytes where !predicate(byte) {
            return false
        }
        return true
    }

    static func numberInRange(_ bytes: ArraySlice<UInt8>, low: Int, high: Int) -> Bool {
        guard allDigits(bytes) else { return false }
        return rangeContains(ByteScan.parseInt(Array(bytes), start: 0, end: bytes.count), low: low, high: high)
    }

    static func rangeContains(_ value: Int, low: Int, high: Int) -> Bool {
        value >= low && value <= high
    }
}
