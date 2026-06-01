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

// Splits a ClickHouse `Tuple(...)` type name into its element entries.
// Top-level commas delimit elements; commas nested inside an element's
// own parentheses (`Decimal(10, 2)`, an inner `Tuple(...)`) do not split.
// The server emits either anonymous (`Tuple(UInt64, String)`) or named
// (`Tuple(a UInt64, b String)`) form; for the named form the leading
// identifier and the type are separated so callers can both parse the
// type and round-trip the name back into the column type string.
enum ClickHouseTupleTypeSplitter {

    struct Element {
        let name: String
        let type: String
    }

    static func split(typeName: String) throws(ClickHouseError) -> [Element] {
        let inner = innerContent(typeName: typeName)
        let segments = try splitTopLevel(inner, typeName: typeName)
        var elements: [Element] = []
        elements.reserveCapacity(segments.count)
        for segment in segments {
            elements.append(separateNameAndType(segment))
        }
        return elements
    }

    static func allNamed(_ names: [String]) -> Bool {
        if names.isEmpty { return false }
        for name in names where name.isEmpty { return false }
        return true
    }

    private static func innerContent(typeName: String) -> String {
        String(typeName.dropFirst("Tuple(".count).dropLast())
    }

    private static func splitTopLevel(_ inner: String, typeName: String) throws(ClickHouseError) -> [String] {
        var scanner = TopLevelScanner()
        for character in inner {
            scanner.consume(character)
        }
        if scanner.depth != 0 {
            throw .protocolError(stage: "decoder.tuple", message: "unbalanced parentheses in \(typeName)")
        }
        return scanner.finished()
    }

    private struct TopLevelScanner {

        private(set) var depth = 0
        private var segments: [String] = []
        private var current: [Character] = []

        mutating func consume(_ character: Character) {
            depth += depthDelta(character)
            if character == "," && depth == 0 {
                flush()
                return
            }
            current.append(character)
        }

        mutating func finished() -> [String] {
            flush()
            return segments
        }

        private mutating func flush() {
            segments.append(String(current))
            current.removeAll(keepingCapacity: true)
        }
    }

    private static let openBrackets: Set<Character> = ["(", "["]
    private static let closeBrackets: Set<Character> = [")", "]"]

    private static func depthDelta(_ character: Character) -> Int {
        if openBrackets.contains(character) { return 1 }
        if closeBrackets.contains(character) { return -1 }
        return 0
    }

    private static func separateNameAndType(_ segment: String) -> Element {
        let trimmed = trim(segment)
        let split = splitLeadingIdentifier(trimmed)
        if split.isNamed {
            return Element(name: split.identifier, type: split.remainder)
        }
        return Element(name: "", type: trimmed)
    }

    private struct LeadingIdentifierSplit {
        let isNamed: Bool
        let identifier: String
        let remainder: String
    }

    private static func splitLeadingIdentifier(_ text: String) -> LeadingIdentifierSplit {
        let scan = scanIdentifier(text)
        let remainder = trim(String(scan.rest))
        if isNamedElement(identifier: scan.identifier, rest: scan.rest, remainder: remainder) {
            return LeadingIdentifierSplit(isNamed: true, identifier: scan.identifier, remainder: remainder)
        }
        return LeadingIdentifierSplit(isNamed: false, identifier: "", remainder: text)
    }

    private static func isNamedElement(identifier: String, rest: Substring, remainder: String) -> Bool {
        if identifier.isEmpty { return false }
        if rest.first != " " { return false }
        return !remainder.isEmpty
    }

    private static func scanIdentifier(_ text: String) -> (identifier: String, rest: Substring) {
        var identifier: [Character] = []
        var rest = Substring(text)
        while let first = rest.first, isIdentifierCharacter(first) {
            identifier.append(first)
            rest = rest.dropFirst()
        }
        return (String(identifier), rest)
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        if character.isLetter { return true }
        if character.isNumber { return true }
        return character == "_"
    }

    private static func trim(_ text: String) -> String {
        var view = Substring(text)
        while view.first == " " { view = view.dropFirst() }
        while view.last == " " { view = view.dropLast() }
        return String(view)
    }
}
