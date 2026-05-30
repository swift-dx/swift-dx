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

enum FormatTemporal {

    static func isDate(_ string: String) -> Bool {
        let bytes = Array(string.utf8)
        guard bytes.count == 10 else { return false }
        return dateBytesValid(bytes)
    }

    static func dateBytesValid(_ bytes: [UInt8]) -> Bool {
        guard bytes[4] == Ascii.hyphen, bytes[7] == Ascii.hyphen else { return false }
        return dateComponentsValid(bytes)
    }

    static func dateComponentsValid(_ bytes: [UInt8]) -> Bool {
        guard FormatScan.allDigits(bytes[0 ..< 4]) else { return false }
        return monthAndDayValid(bytes)
    }

    static func monthAndDayValid(_ bytes: [UInt8]) -> Bool {
        guard FormatScan.numberInRange(bytes[5 ..< 7], low: 1, high: 12) else { return false }
        return FormatScan.numberInRange(bytes[8 ..< 10], low: 1, high: 31)
    }

    static func isTime(_ string: String) -> Bool {
        let bytes = Array(string.utf8)
        guard bytes.count >= 8 else { return false }
        return timePrefixValid(bytes)
    }

    static func timePrefixValid(_ bytes: [UInt8]) -> Bool {
        guard bytes[2] == Ascii.colon, bytes[5] == Ascii.colon else { return false }
        return timeComponentsValid(bytes)
    }

    static func timeComponentsValid(_ bytes: [UInt8]) -> Bool {
        guard FormatScan.numberInRange(bytes[0 ..< 2], low: 0, high: 23) else { return false }
        return minuteAndSecondValid(bytes)
    }

    static func minuteAndSecondValid(_ bytes: [UInt8]) -> Bool {
        guard FormatScan.numberInRange(bytes[3 ..< 5], low: 0, high: 59) else { return false }
        return FormatScan.numberInRange(bytes[6 ..< 8], low: 0, high: 60)
    }

    static func isDateTime(_ string: String) -> Bool {
        let bytes = Array(string.utf8)
        guard bytes.count > 11, isSeparator(bytes[10]) else { return false }
        return halvesValid(bytes)
    }

    static func isSeparator(_ byte: UInt8) -> Bool {
        byte == Ascii.upperT || byte == Ascii.lowerT
    }

    static func halvesValid(_ bytes: [UInt8]) -> Bool {
        let dateText = String(decoding: bytes[0 ..< 10], as: UTF8.self)
        let timeText = String(decoding: bytes[11...], as: UTF8.self)
        return isDate(dateText) && isTime(timeText)
    }

    static func isDuration(_ string: String) -> Bool {
        let bytes = Array(string.utf8)
        guard bytes.count >= 2, bytes[0] == Ascii.upperP else { return false }
        return durationCharsValid(bytes)
    }

    static func durationCharsValid(_ bytes: [UInt8]) -> Bool {
        for index in 1 ..< bytes.count where !isDurationChar(bytes[index]) {
            return false
        }
        return true
    }

    static func isDurationChar(_ byte: UInt8) -> Bool {
        if FormatScan.isDigit(byte) { return true }
        return isDesignator(byte)
    }

    static func isDesignator(_ byte: UInt8) -> Bool {
        switch byte {
        case Ascii.upperY, Ascii.upperM, Ascii.upperW, Ascii.upperD, Ascii.upperT, Ascii.upperH, Ascii.upperS: true
        default: false
        }
    }
}
