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

import Testing
@testable import DXCore

@Suite
struct JSONParserValueTests {

    @Test
    func parsesTrueLiteral() throws {
        #expect(try JSONParser.parse("true") == .bool(true))
    }

    @Test
    func parsesFalseLiteral() throws {
        #expect(try JSONParser.parse("false") == .bool(false))
    }

    @Test
    func parsesNullLiteral() throws {
        #expect(try JSONParser.parse("null") == .null)
    }

    @Test
    func parsesEmptyObject() throws {
        #expect(try JSONParser.parse("{}") == JSONFixtures.object([]))
    }

    @Test
    func parsesEmptyArray() throws {
        #expect(try JSONParser.parse("[]") == JSONFixtures.array([]))
    }

    @Test
    func parsesEmptyString() throws {
        #expect(try JSONParser.parse(#""""#) == .string(""))
    }

    @Test
    func parsesSimpleString() throws {
        #expect(try JSONParser.parse(#""hello""#) == .string("hello"))
    }

    @Test
    func parsesFlatObject() throws {
        let expected = JSONFixtures.object([
            ("name", .string("Ada")),
            ("active", .bool(true)),
        ])
        #expect(try JSONParser.parse(#"{"name":"Ada","active":true}"#) == expected)
    }

    @Test
    func parsesArrayOfMixedScalars() throws {
        let expected = JSONFixtures.array([
            JSONFixtures.signedInteger(1),
            .string("two"),
            .bool(false),
            .null,
        ])
        #expect(try JSONParser.parse(#"[1,"two",false,null]"#) == expected)
    }

    @Test
    func parsesNestedStructure() throws {
        let json = #"{"items":[{"id":1},{"id":2}],"meta":{"count":2}}"#
        let expected = JSONFixtures.object([
            ("items", JSONFixtures.array([
                JSONFixtures.object([("id", JSONFixtures.signedInteger(1))]),
                JSONFixtures.object([("id", JSONFixtures.signedInteger(2))]),
            ])),
            ("meta", JSONFixtures.object([("count", JSONFixtures.signedInteger(2))])),
        ])
        #expect(try JSONParser.parse(json) == expected)
    }

    @Test
    func ignoresInsignificantWhitespace() throws {
        let json = "  {\n  \"a\" : [ 1 , 2 ] ,\t\"b\" : null\r\n}  "
        let expected = JSONFixtures.object([
            ("a", JSONFixtures.array([JSONFixtures.signedInteger(1), JSONFixtures.signedInteger(2)])),
            ("b", .null),
        ])
        #expect(try JSONParser.parse(json) == expected)
    }

    @Test
    func parsesScalarRootNumber() throws {
        #expect(try JSONParser.parse("42") == JSONFixtures.signedInteger(42))
    }

    @Test
    func reportsObjectKindForObject() throws {
        #expect(try JSONParser.parse("{}").kind == .object)
    }

    @Test
    func reportsArrayKindForArray() throws {
        #expect(try JSONParser.parse("[]").kind == .array)
    }

    @Test
    func reportsBooleanKindForBool() throws {
        #expect(try JSONParser.parse("true").kind == .boolean)
    }

    @Test
    func reportsNullKindForNull() throws {
        #expect(try JSONParser.parse("null").kind == .null)
    }

    @Test
    func reportsIntegerKindForWholeNumber() throws {
        #expect(try JSONParser.parse("7").kind == .integer)
    }

    @Test
    func reportsNumberKindForFractionalNumber() throws {
        #expect(try JSONParser.parse("7.5").kind == .number)
    }

    @Test
    func parsesDeeplyButWithinDefaultLimit() throws {
        let value = try JSONParser.parse("[[[[[[1]]]]]]")
        #expect(value.kind == .array)
    }
}
