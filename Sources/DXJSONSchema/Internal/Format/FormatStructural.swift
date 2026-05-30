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

enum FormatStructural {

    static func isUUID(_ string: String) -> Bool {
        let bytes = Array(string.utf8)
        guard bytes.count == 36 else { return false }
        return uuidBytesValid(bytes)
    }

    static func uuidBytesValid(_ bytes: [UInt8]) -> Bool {
        for index in bytes.indices where !uuidByteValid(bytes[index], at: index) {
            return false
        }
        return true
    }

    static func uuidByteValid(_ byte: UInt8, at index: Int) -> Bool {
        if isHyphenPosition(index) { return byte == Ascii.hyphen }
        return FormatScan.isHex(byte)
    }

    static func isHyphenPosition(_ index: Int) -> Bool {
        switch index {
        case 8, 13, 18, 23: true
        default: false
        }
    }

    static func isJSONPointer(_ string: String) -> Bool {
        let bytes = Array(string.utf8)
        guard !bytes.isEmpty else { return true }
        return jsonPointerValid(bytes)
    }

    static func jsonPointerValid(_ bytes: [UInt8]) -> Bool {
        guard bytes[0] == Ascii.slash else { return false }
        return tildesEscaped(bytes)
    }

    static func tildesEscaped(_ bytes: [UInt8]) -> Bool {
        for index in bytes.indices where bytes[index] == Ascii.tilde {
            if !validTildeEscape(bytes, at: index) { return false }
        }
        return true
    }

    static func validTildeEscape(_ bytes: [UInt8], at index: Int) -> Bool {
        guard index + 1 < bytes.count else { return false }
        return isZeroOrOne(bytes[index + 1])
    }

    static func isZeroOrOne(_ byte: UInt8) -> Bool {
        byte == Ascii.digitZero || byte == Ascii.digitZero + 1
    }

    static func isRelativeJSONPointer(_ string: String) -> Bool {
        let bytes = Array(string.utf8)
        guard !bytes.isEmpty else { return false }
        return FormatScan.isDigit(bytes[0])
    }

    static func isRegularExpression(_ string: String) -> Bool {
        switch try? Regex(string) {
        case .some: true
        case .none: false
        }
    }
}
