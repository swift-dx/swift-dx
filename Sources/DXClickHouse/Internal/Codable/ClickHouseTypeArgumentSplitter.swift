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

// Single source of truth for splitting the comma-separated arguments of a
// ClickHouse composite type name (the text between the outermost
// parentheses) into top-level segments. Bracket depth — `()` and `[]` —
// and single-quoted Enum member names (with backslash escapes) are tracked
// so a comma nested inside `Decimal(10, 2)`, an inner `Tuple`, an `Array`
// element, or an Enum label (`'a,b'`) does not split.
//
// Tuple/Variant element parsing, Map key/value splitting, and Geo/Nested
// alias expansion all route through this so the quote and bracket rules
// stay identical across every type-name parse path. Segments are returned
// verbatim; callers trim or separate names as their grammar requires.
enum ClickHouseTypeArgumentSplitter {

    // Returns the top-level segments plus whether the scan closed cleanly
    // (all brackets balanced, no open quote). Callers that treat a
    // malformed type name as an error here — the Tuple parser — check
    // `balanced`; the rest read only `segments`.
    static func topLevel(_ arguments: String) -> (segments: [String], balanced: Bool) {
        var segments: [String] = []
        var current: [Character] = []
        var cursor = Cursor()
        for character in arguments {
            consume(character, cursor: &cursor, current: &current, segments: &segments)
        }
        segments.append(String(current))
        return (segments, cursor.isBalanced)
    }

    private static func consume(
        _ character: Character,
        cursor: inout Cursor,
        current: inout [Character],
        segments: inout [String]
    ) {
        if cursor.advanceIsTopLevelComma(character) {
            segments.append(String(current))
            current.removeAll(keepingCapacity: true)
            return
        }
        current.append(character)
    }

    private struct Cursor {

        private var depth = 0
        private var inQuote = false
        private var escaped = false

        var isBalanced: Bool { depth == 0 && !inQuote }

        mutating func advanceIsTopLevelComma(_ character: Character) -> Bool {
            if consumedAsQuote(character) { return false }
            depth += ClickHouseTypeArgumentSplitter.depthDelta(character)
            return character == "," && depth == 0
        }

        private mutating func consumedAsQuote(_ character: Character) -> Bool {
            if inQuote {
                advanceInsideQuote(character)
                return true
            }
            if character == "'" {
                inQuote = true
                return true
            }
            return false
        }

        private mutating func advanceInsideQuote(_ character: Character) {
            if escaped {
                escaped = false
                return
            }
            escaped = character == "\\"
            if character == "'" { inQuote = false }
        }
    }

    private static let openBrackets: Set<Character> = ["(", "["]
    private static let closeBrackets: Set<Character> = [")", "]"]

    private static func depthDelta(_ character: Character) -> Int {
        if openBrackets.contains(character) { return 1 }
        if closeBrackets.contains(character) { return -1 }
        return 0
    }
}
