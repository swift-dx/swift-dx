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

package enum ByteScan {

    package enum DigitOutcome: Sendable, Equatable {

        case digit(UInt8)
        case invalid
    }

    @inline(__always)
    package static func parseInt<View>(_ view: View, start: Int, end: Int) -> Int
        where View: RandomAccessCollection, View.Element == UInt8, View.Index == Int {
        var value = 0
        for index in start..<end {
            switch decimalDigit(of: view[index]) {
            case .invalid: return value
            case .digit(let digit): value = value &* Int(Radix.decimal) &+ Int(digit)
            }
        }
        return value
    }

    @inline(__always)
    package static func decimalDigit(of byte: UInt8) -> DigitOutcome {
        guard byte >= Ascii.digitZero, byte <= Ascii.digitNine else { return .invalid }
        return .digit(byte - Ascii.digitZero)
    }

    @inline(__always)
    package static func base36Digit(of byte: UInt8) -> DigitOutcome {
        if case .digit(let value) = decimalDigit(of: byte) { return .digit(value) }
        guard byte >= Ascii.lowerA, byte <= Ascii.lowerZ else { return .invalid }
        return .digit(byte - Ascii.lowerA + UInt8(Radix.decimal))
    }

    @inline(__always)
    package static func keyMatches<View>(_ view: View, at index: Int, key: [UInt8]) -> Bool
        where View: RandomAccessCollection, View.Element == UInt8, View.Index == Int {
        for offset in 0..<key.count where view[index + offset] != key[offset] {
            return false
        }
        return true
    }

    @inline(__always)
    package static func skipSpaces<View>(_ view: View, from position: Int, end: Int) -> Int
        where View: RandomAccessCollection, View.Element == UInt8, View.Index == Int {
        var p = position
        while p < end, view[p] == Ascii.space { p &+= 1 }
        return p
    }
}
