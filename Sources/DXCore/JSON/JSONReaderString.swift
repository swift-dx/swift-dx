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

    enum StringByteClass: Sendable, Equatable {

        case closingQuote
        case escape
        case control
        case literal
    }

    enum SurrogateClass: Sendable, Equatable {

        case high
        case low
        case scalar
    }

    mutating func readStringToken() throws(JSONParseError) -> String {
        position &+= 1
        return try scanPlainContent(position)
    }

    mutating func scanPlainContent(_ start: Int) throws(JSONParseError) -> String {
        while true {
            switch classifyStringByte(try currentByte()) {
            case .literal: position &+= 1
            case .closingQuote: return try makePlainString(start)
            case .escape: return try readEscapedString(start)
            case .control: throw .controlCharacterInString(byteOffset: position)
            }
        }
    }

    mutating func makePlainString(_ start: Int) throws(JSONParseError) -> String {
        guard let content = String(validating: bytes[start ..< position], as: UTF8.self) else {
            throw .invalidUTF8(byteOffset: position)
        }
        position &+= 1
        return content
    }

    mutating func readEscapedString(_ start: Int) throws(JSONParseError) -> String {
        var decoded = Array(bytes[start ..< position])
        try scanStringContent(into: &decoded)
        return try decodeUTF8(decoded)
    }

    func decodeUTF8(_ raw: [UInt8]) throws(JSONParseError) -> String {
        guard let string = String(validating: raw, as: UTF8.self) else {
            throw .invalidUTF8(byteOffset: position)
        }
        return string
    }

    mutating func scanStringContent(into decoded: inout [UInt8]) throws(JSONParseError) {
        while true {
            let byte = try currentByte()
            if try handleStringByte(byte, into: &decoded) { return }
        }
    }

    mutating func handleStringByte(_ byte: UInt8, into decoded: inout [UInt8]) throws(JSONParseError) -> Bool {
        switch classifyStringByte(byte) {
        case .closingQuote: return consumeClosingQuote()
        case .escape: return try consumeEscapeContinuing(into: &decoded)
        case .control: throw .controlCharacterInString(byteOffset: position)
        case .literal: return appendLiteralByte(byte, into: &decoded)
        }
    }

    func classifyStringByte(_ byte: UInt8) -> StringByteClass {
        switch byte {
        case Ascii.quote: .closingQuote
        case Ascii.backslash: .escape
        case 0x00 ..< 0x20: .control
        default: .literal
        }
    }

    mutating func consumeClosingQuote() -> Bool {
        position &+= 1
        return true
    }

    mutating func appendLiteralByte(_ byte: UInt8, into decoded: inout [UInt8]) -> Bool {
        decoded.append(byte)
        position &+= 1
        return false
    }

    mutating func consumeEscapeContinuing(into decoded: inout [UInt8]) throws(JSONParseError) -> Bool {
        try consumeEscape(into: &decoded)
        return false
    }

    mutating func consumeEscape(into decoded: inout [UInt8]) throws(JSONParseError) {
        position &+= 1
        let escapeChar = try currentByte()
        try applyEscape(escapeChar, into: &decoded)
    }

    mutating func applyEscape(_ escapeChar: UInt8, into decoded: inout [UInt8]) throws(JSONParseError) {
        switch escapeChar {
        case Ascii.quote: appendByteAdvancing(Ascii.quote, into: &decoded)
        case Ascii.backslash: appendByteAdvancing(Ascii.backslash, into: &decoded)
        case Ascii.slash: appendByteAdvancing(Ascii.slash, into: &decoded)
        case Ascii.lowerB: appendByteAdvancing(0x08, into: &decoded)
        case Ascii.lowerF: appendByteAdvancing(0x0c, into: &decoded)
        case Ascii.lowerN: appendByteAdvancing(Ascii.lineFeed, into: &decoded)
        case Ascii.lowerR: appendByteAdvancing(Ascii.carriageReturn, into: &decoded)
        case Ascii.lowerT: appendByteAdvancing(Ascii.horizontalTab, into: &decoded)
        case Ascii.lowerU: try consumeUnicodeEscape(into: &decoded)
        default: throw .invalidStringEscape(byteOffset: position)
        }
    }

    mutating func appendByteAdvancing(_ byte: UInt8, into decoded: inout [UInt8]) {
        decoded.append(byte)
        position &+= 1
    }

    mutating func consumeUnicodeEscape(into decoded: inout [UInt8]) throws(JSONParseError) {
        position &+= 1
        let unit = try readHex4()
        try appendCodeUnit(unit, into: &decoded)
    }

    mutating func readHex4() throws(JSONParseError) -> UInt16 {
        var value: UInt16 = 0
        for _ in 0 ..< 4 {
            value = try accumulateHex(value)
        }
        return value
    }

    mutating func accumulateHex(_ current: UInt16) throws(JSONParseError) -> UInt16 {
        let byte = try currentByte()
        let digit = try hexDigit(byte)
        position &+= 1
        return current << 4 | UInt16(digit)
    }

    func hexDigit(_ byte: UInt8) throws(JSONParseError) -> UInt8 {
        switch hexValue(byte) {
        case .digit(let value): return value
        case .invalid: throw .invalidUnicodeEscape(byteOffset: position)
        }
    }

    func hexValue(_ byte: UInt8) -> ByteScan.DigitOutcome {
        if case .digit(let value) = ByteScan.decimalDigit(of: byte) { return .digit(value) }
        return hexLetter(byte)
    }

    func hexLetter(_ byte: UInt8) -> ByteScan.DigitOutcome {
        if byte >= Ascii.lowerA, byte <= Ascii.lowerF { return .digit(byte &- Ascii.lowerA &+ 10) }
        if byte >= Ascii.upperA, byte <= Ascii.upperF { return .digit(byte &- Ascii.upperA &+ 10) }
        return .invalid
    }

    mutating func appendCodeUnit(_ unit: UInt16, into decoded: inout [UInt8]) throws(JSONParseError) {
        switch surrogateClass(unit) {
        case .high: try appendSurrogatePair(high: unit, into: &decoded)
        case .low: throw .unpairedSurrogate(byteOffset: position)
        case .scalar: encodeScalar(UInt32(unit), into: &decoded)
        }
    }

    func surrogateClass(_ unit: UInt16) -> SurrogateClass {
        switch unit {
        case 0xD800 ..< 0xDC00: .high
        case 0xDC00 ... 0xDFFF: .low
        default: .scalar
        }
    }

    mutating func appendSurrogatePair(high: UInt16, into decoded: inout [UInt8]) throws(JSONParseError) {
        try expectByte(Ascii.backslash)
        try expectByte(Ascii.lowerU)
        let low = try readHex4()
        try combineSurrogates(high: high, low: low, into: &decoded)
    }

    mutating func expectByte(_ expected: UInt8) throws(JSONParseError) {
        let byte = try currentByte()
        guard byte == expected else { throw .unpairedSurrogate(byteOffset: position) }
        position &+= 1
    }

    mutating func combineSurrogates(high: UInt16, low: UInt16, into decoded: inout [UInt8]) throws(JSONParseError) {
        guard isLowSurrogate(low) else { throw .unpairedSurrogate(byteOffset: position) }
        let scalar = 0x10000 &+ (UInt32(high &- 0xD800) << 10) &+ UInt32(low &- 0xDC00)
        encodeScalar(scalar, into: &decoded)
    }

    func isLowSurrogate(_ unit: UInt16) -> Bool {
        unit >= 0xDC00 && unit <= 0xDFFF
    }
}
