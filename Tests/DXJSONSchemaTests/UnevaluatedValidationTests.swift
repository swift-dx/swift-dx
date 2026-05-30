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
import DXJSONSchema

@Suite
struct UnevaluatedValidationTests {

    @Test
    func unevaluatedPropertiesFalseRejectsExtra() throws {
        let schema = try JSONSchema.compile(#"{"type":"object","properties":{"a":{"type":"integer"}},"unevaluatedProperties":false}"#)
        #expect(schema.validate(#"{"a":1}"#).isValid)
        #expect(!schema.validate(#"{"a":1,"b":2}"#).isValid)
    }

    @Test
    func unevaluatedPropertiesSchemaValidatesExtra() throws {
        let schema = try JSONSchema.compile(#"{"properties":{"a":{"type":"integer"}},"unevaluatedProperties":{"type":"string"}}"#)
        #expect(schema.validate(#"{"a":1,"b":"x"}"#).isValid)
        #expect(!schema.validate(#"{"a":1,"b":2}"#).isValid)
    }

    @Test
    func unevaluatedSeesPatternProperties() throws {
        let schema = try JSONSchema.compile(#"{"patternProperties":{"^x":{"type":"integer"}},"unevaluatedProperties":false}"#)
        #expect(schema.validate(#"{"x1":1}"#).isValid)
        #expect(!schema.validate(#"{"y1":1}"#).isValid)
    }

    @Test
    func unevaluatedSeesAllOfBranch() throws {
        let schema = try JSONSchema.compile(#"{"allOf":[{"properties":{"a":{"type":"integer"}}}],"unevaluatedProperties":false}"#)
        #expect(schema.validate(#"{"a":1}"#).isValid)
        #expect(!schema.validate(#"{"a":1,"b":2}"#).isValid)
    }

    @Test
    func unevaluatedSeesRefTarget() throws {
        let schema = try JSONSchema.compile(##"{"$ref":"#/$defs/base","unevaluatedProperties":false,"$defs":{"base":{"properties":{"a":{"type":"integer"}}}}}"##)
        #expect(schema.validate(#"{"a":1}"#).isValid)
        #expect(!schema.validate(#"{"a":1,"b":2}"#).isValid)
    }

    @Test
    func unevaluatedMergesSuccessfulAnyOfBranches() throws {
        let schema = try JSONSchema.compile(#"{"anyOf":[{"properties":{"a":{"type":"integer"}}},{"properties":{"b":{"type":"integer"}}}],"unevaluatedProperties":false}"#)
        #expect(schema.validate(#"{"a":1}"#).isValid)
        #expect(schema.validate(#"{"a":1,"b":2}"#).isValid)
        #expect(!schema.validate(#"{"a":1,"c":3}"#).isValid)
    }

    @Test
    func unevaluatedIgnoresFailedAnyOfBranch() throws {
        let schema = try JSONSchema.compile(#"{"anyOf":[{"required":["a"],"properties":{"a":{"type":"integer"}}},{"required":["b"],"properties":{"b":{"type":"integer"}}}],"unevaluatedProperties":false}"#)
        #expect(schema.validate(#"{"b":1}"#).isValid)
        #expect(!schema.validate(#"{"b":1,"a":"x"}"#).isValid)
    }

    @Test
    func unevaluatedSeesThenBranchWhenIfMatches() throws {
        let schema = try JSONSchema.compile(#"{"if":{"properties":{"a":{"const":1}}},"then":{"properties":{"b":{"type":"integer"}}},"unevaluatedProperties":false}"#)
        #expect(schema.validate(#"{"a":1,"b":2}"#).isValid)
        #expect(!schema.validate(#"{"a":2}"#).isValid)
    }

    @Test
    func unevaluatedItemsFalseWithPrefixItems() throws {
        let schema = try JSONSchema.compile(#"{"prefixItems":[{"type":"string"}],"unevaluatedItems":false}"#)
        #expect(schema.validate(#"["a"]"#).isValid)
        #expect(!schema.validate(#"["a","b"]"#).isValid)
    }

    @Test
    func unevaluatedItemsSchemaValidatesTail() throws {
        let schema = try JSONSchema.compile(#"{"prefixItems":[{"type":"string"}],"unevaluatedItems":{"type":"integer"}}"#)
        #expect(schema.validate(#"["a",1,2]"#).isValid)
        #expect(!schema.validate(#"["a","b"]"#).isValid)
    }

    @Test
    func unevaluatedItemsSeesContainsMatches() throws {
        let schema = try JSONSchema.compile(#"{"contains":{"type":"integer"},"unevaluatedItems":false}"#)
        #expect(schema.validate("[1,2]").isValid)
        #expect(!schema.validate(#"[1,"x"]"#).isValid)
    }

    @Test
    func unevaluatedCannotSeeInsideCousinBranch() throws {
        let schema = try JSONSchema.compile(#"{"allOf":[{"properties":{"foo":true}},{"unevaluatedProperties":false}]}"#)
        #expect(!schema.validate(#"{"foo":1}"#).isValid)
    }

    @Test
    func unevaluatedInBranchCannotSeeOuterProperties() throws {
        let schema = try JSONSchema.compile(#"{"properties":{"foo":{"type":"string"}},"allOf":[{"unevaluatedProperties":false}],"unevaluatedProperties":true}"#)
        #expect(!schema.validate(#"{"foo":"x"}"#).isValid)
    }

    @Test
    func unevaluatedInRefTargetCannotSeeReferrerProperties() throws {
        let schema = try JSONSchema.compile(##"{"properties":{"prop1":{"type":"string"}},"$ref":"#/$defs/inner","$defs":{"inner":{"unevaluatedProperties":false}}}"##)
        #expect(!schema.validate(#"{"prop1":"x"}"#).isValid)
    }
}
