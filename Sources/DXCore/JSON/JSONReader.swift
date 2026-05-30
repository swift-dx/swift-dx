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

struct JSONReader {

    static let containerCapacityHint = 8

    enum SeparatorOutcome: Sendable, Equatable {

        case more
        case end
    }

    let bytes: [UInt8]
    let end: Int
    let limits: JSONParseLimits
    var position: Int
    var depth: Int

    init(bytes: [UInt8], limits: JSONParseLimits) {
        self.bytes = bytes
        self.end = bytes.count
        self.limits = limits
        self.position = 0
        self.depth = 0
    }

    mutating func parseDocument() throws(JSONParseError) -> JSONValue {
        guard end > 0 else { throw .emptyInput }
        let value = try parseValue()
        skipWhitespace()
        return try requireEndOfInput(value)
    }

    func requireEndOfInput(_ value: JSONValue) throws(JSONParseError) -> JSONValue {
        guard position >= end else { throw .trailingData(byteOffset: position) }
        return value
    }

    mutating func parseValue() throws(JSONParseError) -> JSONValue {
        skipWhitespace()
        let byte = try currentByte()
        return try dispatchValue(byte)
    }

    mutating func dispatchValue(_ byte: UInt8) throws(JSONParseError) -> JSONValue {
        switch byte {
        case Ascii.quote: return .string(try readStringToken())
        case Ascii.braceOpen: return try readObject()
        case Ascii.bracketOpen: return try readArray()
        case Ascii.lowerT: return try readTrueLiteral()
        case Ascii.lowerF: return try readFalseLiteral()
        case Ascii.lowerN: return try readNullLiteral()
        default: return try readNumberToken()
        }
    }

    func currentByte() throws(JSONParseError) -> UInt8 {
        guard position < end else { throw .unexpectedEndOfInput(byteOffset: position) }
        return bytes[position]
    }

    mutating func skipWhitespace() {
        while position < end, isWhitespace(bytes[position]) {
            position &+= 1
        }
    }

    func isWhitespace(_ byte: UInt8) -> Bool {
        switch byte {
        case Ascii.space, Ascii.horizontalTab, Ascii.lineFeed, Ascii.carriageReturn: true
        default: false
        }
    }

    mutating func enterDepth() throws(JSONParseError) {
        depth &+= 1
        guard depth <= limits.maxDepth else { throw .depthLimitExceeded(byteOffset: position, limit: limits.maxDepth) }
    }

    mutating func advanceReturning(_ outcome: SeparatorOutcome) -> SeparatorOutcome {
        position &+= 1
        return outcome
    }

    mutating func readSeparator(closing: UInt8) throws(JSONParseError) -> SeparatorOutcome {
        skipWhitespace()
        let byte = try currentByte()
        return try classifySeparator(byte, closing: closing)
    }

    mutating func classifySeparator(_ byte: UInt8, closing: UInt8) throws(JSONParseError) -> SeparatorOutcome {
        if byte == Ascii.comma { return advanceReturning(.more) }
        if byte == closing { return advanceReturning(.end) }
        throw .unexpectedByte(byteOffset: position, found: byte)
    }

    mutating func consumeClosingIfPresent(_ closing: UInt8) throws(JSONParseError) -> Bool {
        let byte = try currentByte()
        guard byte == closing else { return false }
        position &+= 1
        return true
    }
}
