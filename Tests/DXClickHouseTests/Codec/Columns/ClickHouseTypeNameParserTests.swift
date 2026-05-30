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
import Testing

@Suite("ClickHouse type-name parser")
struct ClickHouseTypeNameParserTests {

    @Test(
        "every simple type name maps to its spec",
        arguments: [
            ("Int8", ClickHouseColumnSpec.int8),
            ("Int16", .int16),
            ("Int32", .int32),
            ("Int64", .int64),
            ("UInt8", .uint8),
            ("UInt16", .uint16),
            ("UInt32", .uint32),
            ("UInt64", .uint64),
            ("Float32", .float32),
            ("Float64", .float64),
            ("String", .string),
            ("Bool", .bool),
            ("Boolean", .bool),
            ("UUID", .uuid),
            ("Date", .date),
            ("Date32", .date32),
            ("IPv4", .ipv4),
            ("IPv6", .ipv6),
        ]
    )
    func simpleTypes(_ input: String, _ expected: ClickHouseColumnSpec) throws {
        let parsed = try ClickHouseTypeNameParser.parse(input)
        #expect(parsed == expected)
    }

    @Test(
        "FixedString lengths parse to the spec",
        arguments: [1, 4, 16, 1024, 1_000_000]
    )
    func fixedStringLengths(_ length: Int) throws {
        let parsed = try ClickHouseTypeNameParser.parse("FixedString(\(length))")
        #expect(parsed == .fixedString(length: length))
    }

    @Test("DateTime without timezone has nil timezone")
    func dateTimeNoTimezone() throws {
        let parsed = try ClickHouseTypeNameParser.parse("DateTime")
        #expect(parsed == .dateTime(timezone: .serverDefault))
    }

    @Test("DateTime with quoted timezone preserves the timezone string")
    func dateTimeWithTimezone() throws {
        let parsed = try ClickHouseTypeNameParser.parse("DateTime('Pacific/Auckland')")
        #expect(parsed == .dateTime(timezone: .explicit("Pacific/Auckland")))
    }

    @Test("DateTime64 with precision only has nil timezone")
    func dateTime64PrecisionOnly() throws {
        let parsed = try ClickHouseTypeNameParser.parse("DateTime64(3)")
        #expect(parsed == .dateTime64(precision: 3, timezone: .serverDefault))
    }

    @Test("DateTime64 with precision and timezone preserves both")
    func dateTime64WithTimezone() throws {
        let parsed = try ClickHouseTypeNameParser.parse("DateTime64(9, 'UTC')")
        #expect(parsed == .dateTime64(precision: 9, timezone: .explicit("UTC")))
    }

    @Test("Array(T) nests correctly")
    func arrayOfSimple() throws {
        let parsed = try ClickHouseTypeNameParser.parse("Array(Int32)")
        #expect(parsed == .array(of: .int32))
    }

    @Test("Nullable(T) nests correctly")
    func nullableOfSimple() throws {
        let parsed = try ClickHouseTypeNameParser.parse("Nullable(String)")
        #expect(parsed == .nullable(of: .string))
    }

    @Test("Tuple parses two-element forms")
    func tupleOfTwo() throws {
        let parsed = try ClickHouseTypeNameParser.parse("Tuple(Int32, String)")
        #expect(parsed == .tuple(elements: [.int32, .string]))
    }

    @Test("Tuple parses three-element forms")
    func tupleOfThree() throws {
        let parsed = try ClickHouseTypeNameParser.parse("Tuple(Int32, String, Bool)")
        #expect(parsed == .tuple(elements: [.int32, .string, .bool]))
    }

    @Test("Tuple with named elements `Tuple(x Int32, y String)` parses as anonymous Tuple(Int32, String) — names are CH metadata only, wire layout is identical")
    func namedTupleParsesAsAnonymous() throws {
        // Pre-fix: the parser saw `x` as the next type identifier and
        // failed with `unknownTypeName("x")`. CH servers DO emit named-
        // tuple type names verbatim when the user declared a column
        // with `Tuple(x Int32, y String)` syntax, so any SELECT
        // touching such a column would fail at type-name parse before
        // it ever reached the codec. ch-go's parser handles this by
        // peeking past an identifier — if the next non-whitespace char
        // is neither `,` nor `)` (i.e., the identifier was a name and
        // a type follows), the name is dropped. We adopt the same
        // strategy. Names are kept as runtime metadata only; the wire
        // bytes for a named tuple are identical to its anonymous form.
        let parsed = try ClickHouseTypeNameParser.parse("Tuple(x Int32, y String)")
        #expect(parsed == .tuple(elements: [.int32, .string]))
    }

    @Test("named tuple with parameterized element types `Tuple(a FixedString(10), b DateTime64(3, 'UTC'))` parses correctly")
    func namedTupleWithParameterizedTypes() throws {
        let parsed = try ClickHouseTypeNameParser.parse("Tuple(a FixedString(10), b DateTime64(3, 'UTC'))")
        let expected: ClickHouseColumnSpec = .tuple(elements: [
            .fixedString(length: 10),
            .dateTime64(precision: 3, timezone: .explicit("UTC"))
        ])
        #expect(parsed == expected)
    }

    @Test("nested Tuple(Tuple(Int32, String), Bool) where the inner Tuple is the element type (NOT a name) parses correctly — peek-ahead must not misread the open-paren as a name boundary")
    func nestedAnonymousTupleNotMistakenForName() throws {
        let parsed = try ClickHouseTypeNameParser.parse("Tuple(Tuple(Int32, String), Bool)")
        let expected: ClickHouseColumnSpec = .tuple(elements: [
            .tuple(elements: [.int32, .string]),
            .bool
        ])
        #expect(parsed == expected)
    }

    @Test("Map parses key-value forms")
    func mapKV() throws {
        let parsed = try ClickHouseTypeNameParser.parse("Map(String, Int64)")
        #expect(parsed == .map(key: .string, value: .int64))
    }

    @Test("nested Array(Nullable(String)) preserves both layers")
    func nestedArrayOfNullable() throws {
        let parsed = try ClickHouseTypeNameParser.parse("Array(Nullable(String))")
        #expect(parsed == .array(of: .nullable(of: .string)))
    }

    @Test("deeply nested Map(String, Array(Tuple(Int32, IPv4))) parses to the recursive shape")
    func deeplyNested() throws {
        let parsed = try ClickHouseTypeNameParser.parse("Map(String, Array(Tuple(Int32, IPv4)))")
        let expected: ClickHouseColumnSpec = .map(
            key: .string,
            value: .array(of: .tuple(elements: [.int32, .ipv4]))
        )
        #expect(parsed == expected)
    }

    @Test("whitespace tolerance: extra spaces between tokens parse identically")
    func whitespaceTolerance() throws {
        let cases = [
            "Tuple(Int32,String)",
            "Tuple(Int32, String)",
            "Tuple( Int32 , String )",
            "  Tuple(Int32, String)  ",
        ]
        let expected: ClickHouseColumnSpec = .tuple(elements: [.int32, .string])
        for input in cases {
            #expect(try ClickHouseTypeNameParser.parse(input) == expected)
        }
    }

    @Test("doubled-quote escape inside a timezone string is decoded as one quote")
    func doubledQuoteEscapeInTimezone() throws {
        let parsed = try ClickHouseTypeNameParser.parse("DateTime('quirk''name')")
        #expect(parsed == .dateTime(timezone: .explicit("quirk'name")))
    }

    @Test("unknown type name surfaces a typed error")
    func unknownTypeRejected() {
        #expect(throws: ClickHouseError.unknownTypeName("Quaternion")) {
            try ClickHouseTypeNameParser.parse("Quaternion")
        }
    }

    @Test("missing closing paren on a composite type surfaces a typed error")
    func missingClosingParenRejected() {
        #expect(throws: ClickHouseError.self) {
            try ClickHouseTypeNameParser.parse("Array(Int32")
        }
    }

    @Test("missing argument list on FixedString surfaces a typed error")
    func missingArgumentListRejected() {
        #expect(throws: ClickHouseError.self) {
            try ClickHouseTypeNameParser.parse("FixedString")
        }
    }

    @Test("trailing junk after a valid type surfaces a typed error")
    func trailingJunkRejected() {
        #expect(throws: ClickHouseError.self) {
            try ClickHouseTypeNameParser.parse("Int32 unexpected")
        }
    }

    @Test("unterminated quoted string surfaces a typed error")
    func unterminatedQuoteRejected() {
        #expect(throws: ClickHouseError.self) {
            try ClickHouseTypeNameParser.parse("DateTime('UTC")
        }
    }

    @Test("nesting beyond the depth limit surfaces a typed error")
    func nestingDepthLimitEnforced() {
        let depth = ClickHouseTypeNameParser.maxNestingDepth + 1
        let input = String(repeating: "Array(", count: depth) + "Int32" + String(repeating: ")", count: depth)
        do {
            _ = try ClickHouseTypeNameParser.parse(input)
            Issue.record("expected nesting-depth error")
        } catch let ClickHouseError.typeNameNestingTooDeep(maxDepth) {
            #expect(maxDepth == ClickHouseTypeNameParser.maxNestingDepth)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("nesting at exactly the depth limit parses successfully")
    func nestingAtLimitParses() throws {
        let depth = ClickHouseTypeNameParser.maxNestingDepth - 1
        let input = String(repeating: "Array(", count: depth) + "Int32" + String(repeating: ")", count: depth)
        let parsed = try ClickHouseTypeNameParser.parse(input)
        #expect(parsed.specDescription.contains("array"))
    }

    @Test("parsed spec round-trips back through the registry for a representative nest")
    func parserAndRegistryAlign() throws {
        let parsed = try ClickHouseTypeNameParser.parse("Map(String, Array(Nullable(Int64)))")
        guard case .map(let key, let value) = parsed else {
            Issue.record("expected map")
            return
        }
        #expect(key == .string)
        guard case .array(let element) = value else {
            Issue.record("expected array")
            return
        }
        #expect(element == .nullable(of: .int64))
    }

}

private extension ClickHouseColumnSpec {

    var specDescription: String {
        switch self {
        case .array: return "array"
        case .nullable: return "nullable"
        case .tuple: return "tuple"
        case .map: return "map"
        default: return "other"
        }
    }

}
