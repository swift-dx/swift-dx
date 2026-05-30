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

extension JSONReader {

    mutating func readNumberToken() throws(JSONParseError) -> JSONValue {
        let start = position
        let isDecimal = try scanNumber()
        return makeNumber(start: start, isDecimal: isDecimal)
    }

    mutating func scanNumber() throws(JSONParseError) -> Bool {
        _ = consumeByteIf(Ascii.hyphen)
        try scanIntegerPart()
        let fraction = try scanOptionalFraction()
        let exponent = try scanOptionalExponent()
        return fraction || exponent
    }

    mutating func consumeByteIf(_ expected: UInt8) -> Bool {
        guard position < end, bytes[position] == expected else { return false }
        position &+= 1
        return true
    }

    mutating func scanIntegerPart() throws(JSONParseError) {
        let byte = try currentByte()
        try requireDigit(byte)
        try scanIntegerRemainder(firstDigit: byte)
    }

    mutating func scanIntegerRemainder(firstDigit: UInt8) throws(JSONParseError) {
        position &+= 1
        guard firstDigit != Ascii.digitZero else { return }
        consumeDigits()
    }

    func requireDigit(_ byte: UInt8) throws(JSONParseError) {
        guard isDigit(byte) else { throw .invalidNumber(byteOffset: position) }
    }

    func isDigit(_ byte: UInt8) -> Bool {
        byte >= Ascii.digitZero && byte <= Ascii.digitNine
    }

    mutating func consumeDigits() {
        while position < end, isDigit(bytes[position]) {
            position &+= 1
        }
    }

    mutating func scanOptionalFraction() throws(JSONParseError) -> Bool {
        guard consumeByteIf(Ascii.dot) else { return false }
        try scanRequiredDigits()
        return true
    }

    mutating func scanRequiredDigits() throws(JSONParseError) {
        let byte = try currentByte()
        try requireDigit(byte)
        consumeDigits()
    }

    mutating func scanOptionalExponent() throws(JSONParseError) -> Bool {
        guard consumeExponentMarker() else { return false }
        _ = consumeSign()
        try scanRequiredDigits()
        return true
    }

    mutating func consumeExponentMarker() -> Bool {
        guard position < end else { return false }
        return consumeIfExponentByte(bytes[position])
    }

    mutating func consumeIfExponentByte(_ byte: UInt8) -> Bool {
        switch byte {
        case Ascii.lowerE, Ascii.upperE: return advanceTrue()
        default: return false
        }
    }

    mutating func consumeSign() -> Bool {
        guard position < end else { return false }
        return consumeIfSignByte(bytes[position])
    }

    mutating func consumeIfSignByte(_ byte: UInt8) -> Bool {
        switch byte {
        case Ascii.plus, Ascii.hyphen: return advanceTrue()
        default: return false
        }
    }

    mutating func advanceTrue() -> Bool {
        position &+= 1
        return true
    }

    func makeNumber(start: Int, isDecimal: Bool) -> JSONValue {
        guard !isDecimal else { return decimalNumber(start) }
        return integerNumber(start)
    }

    func integerNumber(_ start: Int) -> JSONValue {
        switch accumulateInteger(start) {
        case .signed(let value): return .number(JSONNumber(form: .signedInteger(value)))
        case .unsigned(let value): return .number(JSONNumber(form: .unsignedInteger(value)))
        case .tooBig: return decimalNumber(start)
        }
    }

    func decimalNumber(_ start: Int) -> JSONValue {
        let source = String(decoding: bytes[start ..< position], as: UTF8.self)
        return .number(JSONNumber(form: .decimal(parseDouble(source))))
    }

    func accumulateInteger(_ start: Int) -> NumberIntegerForm {
        let negative = bytes[start] == Ascii.hyphen
        return foldDigits(from: negative ? start &+ 1 : start, negative: negative)
    }

    func foldDigits(from first: Int, negative: Bool) -> NumberIntegerForm {
        var magnitude: UInt64 = 0
        var overflow = false
        for index in first ..< position {
            (magnitude, overflow) = step(magnitude, bytes[index], overflow)
        }
        return resolveSign(magnitude, negative: negative, overflow: overflow)
    }

    func step(_ magnitude: UInt64, _ byte: UInt8, _ overflow: Bool) -> (UInt64, Bool) {
        guard !overflow else { return (magnitude, true) }
        return multiplyAdd(magnitude, UInt64(byte &- Ascii.digitZero))
    }

    func multiplyAdd(_ magnitude: UInt64, _ digit: UInt64) -> (UInt64, Bool) {
        let scaled = magnitude.multipliedReportingOverflow(by: 10)
        let summed = scaled.partialValue.addingReportingOverflow(digit)
        return (summed.partialValue, scaled.overflow || summed.overflow)
    }

    func resolveSign(_ magnitude: UInt64, negative: Bool, overflow: Bool) -> NumberIntegerForm {
        guard !overflow else { return .tooBig }
        return negative ? negativeForm(magnitude) : positiveForm(magnitude)
    }

    func positiveForm(_ magnitude: UInt64) -> NumberIntegerForm {
        guard magnitude > UInt64(Int64.max) else { return .signed(Int64(magnitude)) }
        return .unsigned(magnitude)
    }

    func negativeForm(_ magnitude: UInt64) -> NumberIntegerForm {
        guard magnitude > UInt64(Int64.max) else { return .signed(0 &- Int64(magnitude)) }
        return negativeBoundary(magnitude)
    }

    func negativeBoundary(_ magnitude: UInt64) -> NumberIntegerForm {
        guard magnitude == UInt64(Int64.max) &+ 1 else { return .tooBig }
        return .signed(Int64.min)
    }

    func parseDouble(_ source: String) -> Double {
        if let value = Double(source) { return value }
        return 0
    }
}

enum NumberIntegerForm: Sendable, Equatable {

    case signed(Int64)
    case unsigned(UInt64)
    case tooBig
}
