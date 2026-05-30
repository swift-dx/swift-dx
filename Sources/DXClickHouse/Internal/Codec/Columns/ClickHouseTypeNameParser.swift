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

// Recursive-descent parser that turns a ClickHouse type name (e.g.
// "Array(Nullable(String))", "Map(String, Tuple(Int32, IPv4))",
// "DateTime64(3, 'Pacific/Auckland')") into a ClickHouseColumnSpec.
//
// The parser is allocation-light: it walks String.Index forward over the
// input rather than slicing into substrings per token. A depth counter
// caps recursive nesting to bound DoS exposure from a hostile peer.
struct ClickHouseTypeNameParser {

    static let maxNestingDepth = 32

    private let input: String
    private var index: String.Index
    private var depth: Int

    private init(_ input: String) {
        self.input = input
        self.index = input.startIndex
        self.depth = 0
    }

    static func parse(_ typeName: String) throws -> ClickHouseColumnSpec {
        var parser = Self(typeName)
        let spec = try parser.parseSpec()
        parser.skipWhitespace()
        guard parser.index == parser.input.endIndex else {
            throw parser.malformed(message: "unexpected trailing input")
        }
        return spec
    }

    private mutating func parseSpec() throws -> ClickHouseColumnSpec {
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maxNestingDepth else {
            throw ClickHouseError.typeNameNestingTooDeep(maxDepth: Self.maxNestingDepth)
        }

        skipWhitespace()
        let name = try parseIdentifier()
        switch name {
        case "Int8": return .int8
        case "Int16": return .int16
        case "Int32": return .int32
        case "Int64": return .int64
        case "Int128": return .int128
        case "UInt8": return .uint8
        case "UInt16": return .uint16
        case "UInt32": return .uint32
        case "UInt64": return .uint64
        case "UInt128": return .uint128
        case "Float32": return .float32
        case "Float64": return .float64
        case "String": return .string
        case "Bool", "Boolean": return .bool
        case "UUID": return .uuid
        case "Date": return .date
        case "Date32": return .date32
        case "IPv4": return .ipv4
        case "IPv6": return .ipv6
        case "FixedString": return try parseFixedString()
        case "DateTime": return try parseDateTime()
        case "DateTime64": return try parseDateTime64()
        case "Array": return try parseArray()
        case "Nullable": return try parseNullable()
        case "Tuple": return try parseTuple()
        case "Map": return try parseMap()
        case "LowCardinality": return try parseLowCardinality()
        case "Enum8": return .enum8(try parseEnumEntries(as: Int8.self))
        case "Enum16": return .enum16(try parseEnumEntries(as: Int16.self))
        case "Decimal32": return try parseDecimal32()
        case "Decimal64": return try parseDecimal64()
        case "Decimal128": return try parseDecimal128()
        case "Decimal256": return try parseDecimal256()
        case "Decimal": return try parseDecimalAlias()
        case "Int256": return .int256
        case "UInt256": return .uint256
        case "BFloat16": return .bfloat16
        case "Nothing": return .nothing
        case "JSON": return .json
        case "Time": return .time
        case "Time64": return try parseTime64()
        case "Point": return Self.pointSpec
        case "Ring": return Self.ringSpec
        case "Polygon": return Self.polygonSpec
        case "MultiPolygon": return Self.multiPolygonSpec
        default:
            if let kind = ClickHouseIntervalKind(typeName: name) {
                return .interval(kind: kind)
            }
            throw ClickHouseError.unknownTypeName(name)
        }
    }

    // ClickHouse Geographic types are pure aliases over Tuple+Array. The
    // server emits `Point` / `Ring` / `Polygon` / `MultiPolygon` in column
    // metadata when the column was declared with that alias; the underlying
    // wire format is identical to the composite expansion below.
    private static let pointSpec: ClickHouseColumnSpec = .tuple(elements: [.float64, .float64])
    private static let ringSpec: ClickHouseColumnSpec = .array(of: pointSpec)
    private static let polygonSpec: ClickHouseColumnSpec = .array(of: ringSpec)
    private static let multiPolygonSpec: ClickHouseColumnSpec = .array(of: polygonSpec)

    private mutating func parseTime64() throws -> ClickHouseColumnSpec {
        try expectChar("(")
        skipWhitespace()
        let precision = try parseInt()
        skipWhitespace()
        try expectChar(")")
        return .time64(precision: precision)
    }

    private mutating func parseDecimal32() throws -> ClickHouseColumnSpec {
        try expectChar("(")
        skipWhitespace()
        let scale = try parseInt()
        skipWhitespace()
        try expectChar(")")
        return .decimal32(scale: scale)
    }

    private mutating func parseDecimal64() throws -> ClickHouseColumnSpec {
        try expectChar("(")
        skipWhitespace()
        let scale = try parseInt()
        skipWhitespace()
        try expectChar(")")
        return .decimal64(scale: scale)
    }

    private mutating func parseDecimal128() throws -> ClickHouseColumnSpec {
        try expectChar("(")
        skipWhitespace()
        let scale = try parseInt()
        skipWhitespace()
        try expectChar(")")
        return .decimal128(scale: scale)
    }

    private mutating func parseDecimal256() throws -> ClickHouseColumnSpec {
        try expectChar("(")
        skipWhitespace()
        let scale = try parseInt()
        skipWhitespace()
        try expectChar(")")
        return .decimal256(scale: scale)
    }

    private mutating func parseDecimalAlias() throws -> ClickHouseColumnSpec {
        try expectChar("(")
        skipWhitespace()
        let precision = try parseInt()
        skipWhitespace()
        try expectChar(",")
        skipWhitespace()
        let scale = try parseInt()
        skipWhitespace()
        try expectChar(")")
        switch precision {
        case ...9: return .decimal32(scale: scale)
        case ...18: return .decimal64(scale: scale)
        case ...38: return .decimal128(scale: scale)
        case ...76: return .decimal256(scale: scale)
        default:
            throw malformed(message: "Decimal precision \(precision) exceeds Decimal256's 76-digit maximum")
        }
    }

    private mutating func parseLowCardinality() throws -> ClickHouseColumnSpec {
        try expectChar("(")
        let inner = try parseSpec()
        skipWhitespace()
        try expectChar(")")
        return .lowCardinality(of: inner)
    }

    private mutating func parseEnumEntries<T: FixedWidthInteger & Sendable & Hashable>(as type: T.Type) throws -> [ClickHouseEnumValue<T>] {
        try expectChar("(")
        var entries: [ClickHouseEnumValue<T>] = []
        entries.append(try parseEnumEntry(as: type))
        skipWhitespace()
        while peek() == "," {
            _ = consume()
            entries.append(try parseEnumEntry(as: type))
            skipWhitespace()
        }
        try expectChar(")")
        return entries
    }

    private mutating func parseEnumEntry<T: FixedWidthInteger & Sendable & Hashable>(as type: T.Type) throws -> ClickHouseEnumValue<T> {
        skipWhitespace()
        let name = try parseQuotedString()
        skipWhitespace()
        try expectChar("=")
        skipWhitespace()
        let raw = try parseInt()
        guard let value = T(exactly: raw) else {
            throw malformed(message: "enum value \(raw) does not fit in \(T.self)")
        }
        return ClickHouseEnumValue(name: name, value: value)
    }

    private mutating func parseFixedString() throws -> ClickHouseColumnSpec {
        try expectChar("(")
        skipWhitespace()
        let length = try parseInt()
        skipWhitespace()
        try expectChar(")")
        return .fixedString(length: length)
    }

    private mutating func parseDateTime() throws -> ClickHouseColumnSpec {
        skipWhitespace()
        guard peek() == "(" else { return .dateTime(timezone: .serverDefault) }
        _ = consume()
        skipWhitespace()
        let timezone = try parseQuotedString()
        skipWhitespace()
        try expectChar(")")
        return .dateTime(timezone: .explicit(timezone))
    }

    private mutating func parseDateTime64() throws -> ClickHouseColumnSpec {
        try expectChar("(")
        skipWhitespace()
        let precision = try parseInt()
        skipWhitespace()
        if peek() == "," {
            _ = consume()
            skipWhitespace()
            let timezone = try parseQuotedString()
            skipWhitespace()
            try expectChar(")")
            return .dateTime64(precision: precision, timezone: .explicit(timezone))
        }
        try expectChar(")")
        return .dateTime64(precision: precision, timezone: .serverDefault)
    }

    private mutating func parseArray() throws -> ClickHouseColumnSpec {
        try expectChar("(")
        let element = try parseSpec()
        skipWhitespace()
        try expectChar(")")
        return .array(of: element)
    }

    private mutating func parseNullable() throws -> ClickHouseColumnSpec {
        try expectChar("(")
        let inner = try parseSpec()
        skipWhitespace()
        try expectChar(")")
        return .nullable(of: inner)
    }

    private mutating func parseTuple() throws -> ClickHouseColumnSpec {
        try expectChar("(")
        var elements: [ClickHouseColumnSpec] = []
        elements.append(try parseTupleElement())
        skipWhitespace()
        while peek() == "," {
            _ = consume()
            elements.append(try parseTupleElement())
            skipWhitespace()
        }
        try expectChar(")")
        return .tuple(elements: elements)
    }

    // CH server emits named-tuple syntax (`Tuple(x Int32, y String)`)
    // verbatim in column type-name metadata when the column was
    // declared with named elements. Names are pure metadata: the wire
    // layout is identical to an anonymous Tuple. We honour the syntax
    // by peeking past a leading identifier — if the next non-whitespace
    // character is anything OTHER than `,`, `)`, or `(`, that identifier
    // was an element name and a type follows. Open-paren means the
    // identifier IS a parameterized type (e.g., `FixedString(10)`), so
    // we rewind and let `parseSpec()` reparse it. Comma or close-paren
    // means the identifier WAS the type (anonymous element).
    //
    // Names are dropped on purpose: ClickHouseColumnSpec.tuple stores
    // only the element types, and downstream codecs index by position.
    // The same dropping happens on encode (typeName emits anonymous
    // form), and CH server accepts assignment between named and
    // anonymous tuples of compatible structure.
    private mutating func parseTupleElement() throws -> ClickHouseColumnSpec {
        skipWhitespace()
        let savedIndex = index
        if leadingIdentifierIsElementName() {
            return try parseSpec()
        }
        index = savedIndex
        return try parseSpec()
    }

    private mutating func leadingIdentifierIsElementName() -> Bool {
        guard (try? parseIdentifier()) != nil else { return false }
        skipWhitespace()
        let lookahead = peek()
        return !isTupleElementBoundary(lookahead)
    }

    private func isTupleElementBoundary(_ character: ScannerChar) -> Bool {
        switch character {
        case ",", ")", "(": true
        default: false
        }
    }

    private mutating func parseMap() throws -> ClickHouseColumnSpec {
        try expectChar("(")
        let key = try parseSpec()
        skipWhitespace()
        try expectChar(",")
        let value = try parseSpec()
        skipWhitespace()
        try expectChar(")")
        return .map(key: key, value: value)
    }

    // -- low-level helpers --

    private mutating func skipWhitespace() {
        while index < input.endIndex, input[index].isWhitespace {
            index = input.index(after: index)
        }
    }

    private func peek() -> ScannerChar {
        guard index < input.endIndex else { return .endOfInput }
        return .character(input[index])
    }

    private mutating func consume() -> ScannerChar {
        guard index < input.endIndex else { return .endOfInput }
        let character = input[index]
        index = input.index(after: index)
        return .character(character)
    }

    private mutating func expectChar(_ expected: Character) throws {
        skipWhitespace()
        let position = currentOffset
        guard case .character(let actual) = consume(), actual == expected else {
            throw ClickHouseError.malformedTypeName(
                at: position,
                message: "expected '\(expected)'"
            )
        }
    }

    private mutating func parseIdentifier() throws -> String {
        skipWhitespace()
        let start = index
        consumeIdentifierBody()
        guard start < index else {
            throw malformed(message: "expected identifier")
        }
        return String(input[start..<index])
    }

    private mutating func consumeIdentifierBody() {
        while case .character(let character) = peek(), isIdentifierCharacter(character) {
            _ = consume()
        }
    }

    private func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private mutating func parseInt() throws -> Int {
        skipWhitespace()
        let start = index
        consumeIntegerLiteral()
        guard start < index, let value = Int(input[start..<index]) else {
            throw malformed(message: "expected integer")
        }
        return value
    }

    private mutating func consumeIntegerLiteral() {
        if peek() == "-" {
            _ = consume()
        }
        while case .character(let character) = peek(), character.isNumber {
            _ = consume()
        }
    }

    private mutating func parseQuotedString() throws -> String {
        try expectChar("'")
        var result = ""
        while case .character(let character) = peek() {
            if try appendQuotedCharacter(character, into: &result) {
                return result
            }
        }
        throw malformed(message: "unterminated quoted string")
    }

    private mutating func appendQuotedCharacter(_ character: Character, into result: inout String) throws -> Bool {
        if character == "'" {
            return handleSingleQuote(into: &result)
        }
        result.append(character)
        _ = consume()
        return false
    }

    private mutating func handleSingleQuote(into result: inout String) -> Bool {
        let nextIndex = input.index(after: index)
        if nextIndex < input.endIndex, input[nextIndex] == "'" {
            result.append("'")
            _ = consume()
            _ = consume()
            return false
        }
        _ = consume()
        return true
    }

    private var currentOffset: Int {
        input.distance(from: input.startIndex, to: index)
    }

    private func malformed(message: String) -> ClickHouseError {
        .malformedTypeName(at: currentOffset, message: message)
    }

}

// Typed alternative to `Character?` for the parser's lookahead and
// consumption primitives. `.endOfInput` makes "no more bytes" a named
// state instead of a nil sentinel, so call sites switch on the case
// explicitly rather than chasing optional unwraps.
private enum ScannerChar: Equatable, ExpressibleByExtendedGraphemeClusterLiteral {

    case character(Character)
    case endOfInput

    init(extendedGraphemeClusterLiteral value: Character) {
        self = .character(value)
    }

}
