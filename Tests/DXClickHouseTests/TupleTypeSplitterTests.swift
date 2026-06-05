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

// The Tuple/Variant type-name splitter must treat brackets and commas
// inside an Enum's quoted member names as literal text, not as structure.
// ClickHouse permits arbitrary characters in Enum names, so a descriptive
// name like 'error (' carries an unbalanced parenthesis; without quote
// awareness the splitter miscounts depth and either mis-splits the tuple
// or rejects a perfectly valid column type.
@Suite("Tuple type-name splitter is quote-aware")
struct TupleTypeSplitterTests {

    private static func types(_ typeName: String) throws -> [String] {
        try ClickHouseTupleTypeSplitter.split(typeName: typeName).map(\.type)
    }

    @Test("a plain Tuple still splits on top-level commas")
    func plainTupleSplits() throws {
        #expect(try Self.types("Tuple(UInt64, String)") == ["UInt64", "String"])
    }

    @Test("a comma nested in a Decimal does not split")
    func nestedDecimalDoesNotSplit() throws {
        #expect(try Self.types("Tuple(Decimal(10, 2), String)") == ["Decimal(10, 2)", "String"])
    }

    @Test("an unbalanced bracket inside an Enum member name does not break the split")
    func enumNameWithUnbalancedBracketSplits() throws {
        let elements = try Self.types("Tuple(code Enum8('error (' = 1, 'ok' = 2), value UInt64)")
        #expect(elements == ["Enum8('error (' = 1, 'ok' = 2)", "UInt64"])
    }

    @Test("a comma inside an Enum member name does not split when its parens are unbalanced")
    func enumNameWithBracketAndCommaSplits() throws {
        let elements = try Self.types("Tuple(code Enum8('a),b' = 1), value String)")
        #expect(elements == ["Enum8('a),b' = 1)", "String"])
    }
}
