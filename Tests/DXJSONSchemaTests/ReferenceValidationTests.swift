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
struct ReferenceValidationTests {

    @Test
    func refToDefsResolves() throws {
        let schema = try JSONSchema.compile(##"{"type":"object","properties":{"a":{"$ref":"#/$defs/pos"}},"$defs":{"pos":{"type":"integer","minimum":0}}}"##)
        #expect(schema.validate(##"{"a":5}"##).isValid)
        #expect(!schema.validate(##"{"a":-1}"##).isValid)
        #expect(!schema.validate(##"{"a":"x"}"##).isValid)
    }

    @Test
    func recursiveRootRefValidatesNestedStructure() throws {
        let schema = try JSONSchema.compile(##"{"type":"object","additionalProperties":false,"properties":{"value":{"type":"integer"},"next":{"$ref":"#"}}}"##)
        #expect(schema.validate(##"{"value":1,"next":{"value":2,"next":{"value":3}}}"##).isValid)
        #expect(!schema.validate(##"{"value":1,"next":{"value":"x"}}"##).isValid)
    }

    @Test
    func anchorRefResolves() throws {
        let schema = try JSONSchema.compile(##"{"$defs":{"foo":{"$anchor":"Foo","type":"string"}},"properties":{"x":{"$ref":"#Foo"}}}"##)
        #expect(schema.validate(##"{"x":"hi"}"##).isValid)
        #expect(!schema.validate(##"{"x":5}"##).isValid)
    }

    @Test
    func refSiblingsAlsoApply() throws {
        let schema = try JSONSchema.compile(##"{"$ref":"#/$defs/base","minimum":10,"$defs":{"base":{"type":"integer"}}}"##)
        #expect(schema.validate("15").isValid)
        #expect(!schema.validate("5").isValid)
        #expect(!schema.validate(##""x""##).isValid)
    }

    @Test
    func pointerDecodesEscapedTokens() throws {
        let schema = try JSONSchema.compile(##"{"properties":{"a":{"$ref":"#/$defs/a~1b"}},"$defs":{"a/b":{"type":"integer"}}}"##)
        #expect(schema.validate(##"{"a":1}"##).isValid)
        #expect(!schema.validate(##"{"a":"x"}"##).isValid)
    }

    @Test
    func unresolvedLocalRefThrows() {
        #expect(throws: JSONSchemaError.self) {
            try JSONSchema.compile(##"{"$ref":"#/$defs/missing"}"##)
        }
    }

    @Test
    func externalRefThrows() {
        #expect(throws: JSONSchemaError.self) {
            try JSONSchema.compile(##"{"$ref":"https://example.com/schema.json"}"##)
        }
    }
}
