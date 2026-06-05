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

@testable import DXClickHouse
import Foundation
import Testing

// The shared top-level argument splitter is the single source of truth the
// Tuple, Map, and Geo type-name parsers all route through. These cases pin
// the quote- and bracket-awareness that each of those parsers relies on.
@Suite("Shared type-argument splitter")
struct TypeArgumentSplitterTests {

    private static func split(_ s: String) -> [String] {
        ClickHouseTypeArgumentSplitter.topLevel(s).segments
    }

    @Test("splits plain top-level commas")
    func plain() {
        #expect(Self.split("UInt64, String") == ["UInt64", " String"])
    }

    @Test("a comma nested in parentheses does not split")
    func nestedParens() {
        #expect(Self.split("Decimal(10, 2), String") == ["Decimal(10, 2)", " String"])
    }

    @Test("a comma nested in brackets does not split")
    func nestedBrackets() {
        #expect(Self.split("Array(UInt64)[0, 1], String") == ["Array(UInt64)[0, 1]", " String"])
    }

    @Test("a comma inside a quoted Enum member name does not split")
    func quotedComma() {
        #expect(Self.split("Enum8('a,b' = 1, 'c' = 2), String") == ["Enum8('a,b' = 1, 'c' = 2)", " String"])
    }

    @Test("an unbalanced bracket inside a quoted name does not break the split")
    func quotedUnbalancedBracket() {
        #expect(Self.split("Enum8('a(' = 1), String") == ["Enum8('a(' = 1)", " String"])
    }

    @Test("an escaped quote inside a name does not end the quote")
    func escapedQuote() {
        #expect(Self.split("Enum8('a\\',b' = 1), String") == ["Enum8('a\\',b' = 1)", " String"])
    }

    @Test("no top-level comma yields a single segment")
    func single() {
        #expect(Self.split("Tuple(a UInt64, b String)") == ["Tuple(a UInt64, b String)"])
    }
}
