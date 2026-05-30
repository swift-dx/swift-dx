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
struct ApplicatorValidationTests {

    static let personSchema = #"""
    {
      "type": "object",
      "required": ["name", "age"],
      "additionalProperties": false,
      "properties": {
        "name": {"type": "string", "minLength": 1},
        "age": {"type": "integer", "minimum": 0},
        "tags": {"type": "array", "items": {"type": "string"}}
      }
    }
    """#

    @Test
    func validPersonPasses() throws {
        let schema = try JSONSchema.compile(Self.personSchema)
        #expect(schema.validate(#"{"name":"Ada","age":36,"tags":["x","y"]}"#).isValid)
    }

    @Test
    func missingRequiredPropertyFails() throws {
        let schema = try JSONSchema.compile(Self.personSchema)
        #expect(!schema.validate(#"{"name":"Ada"}"#).isValid)
    }

    @Test
    func additionalPropertyRejected() throws {
        let schema = try JSONSchema.compile(Self.personSchema)
        let result = schema.validate(#"{"name":"Ada","age":36,"extra":1}"#)
        #expect(!result.isValid)
        #expect(result.violations.contains { $0.instanceLocation == "/extra" })
    }

    @Test
    func nestedPropertyViolationReportsInstanceLocation() throws {
        let schema = try JSONSchema.compile(Self.personSchema)
        let result = schema.validate(#"{"name":"","age":36}"#)
        #expect(result.violations.contains { $0.instanceLocation == "/name" && $0.keyword == "minLength" })
    }

    @Test
    func arrayItemTypeViolationReportsIndexedLocation() throws {
        let schema = try JSONSchema.compile(Self.personSchema)
        let result = schema.validate(#"{"name":"Ada","age":1,"tags":["ok",7]}"#)
        #expect(result.violations.contains { $0.instanceLocation == "/tags/1" && $0.keyword == "type" })
    }

    @Test
    func additionalPropertiesSchemaValidatesExtraValues() throws {
        let schema = try JSONSchema.compile(#"{"properties":{"a":{"type":"string"}},"additionalProperties":{"type":"integer"}}"#)
        #expect(schema.validate(#"{"a":"x","b":7}"#).isValid)
        #expect(!schema.validate(#"{"a":"x","b":"y"}"#).isValid)
    }

    @Test
    func itemsWithoutPrefixAppliesToAll() throws {
        let schema = try JSONSchema.compile(#"{"type":"array","items":{"type":"integer"}}"#)
        #expect(schema.validate("[1,2,3]").isValid)
        #expect(!schema.validate("[1,\"two\"]").isValid)
    }

    @Test
    func booleanTrueSchemaAlwaysValid() throws {
        let schema = try JSONSchema.compile("true")
        #expect(schema.validate(#"{"anything":[1,2]}"#).isValid)
    }

    @Test
    func booleanFalseSchemaAlwaysInvalid() throws {
        let schema = try JSONSchema.compile("false")
        #expect(!schema.validate("1").isValid)
    }

    @Test
    func falsePropertySchemaForbidsThatProperty() throws {
        let schema = try JSONSchema.compile(#"{"properties":{"forbidden":false}}"#)
        #expect(schema.validate(#"{"allowed":1}"#).isValid)
        #expect(!schema.validate(#"{"forbidden":1}"#).isValid)
    }

    @Test
    func deeplyNestedStructureValidates() throws {
        let schema = try JSONSchema.compile(#"{"type":"object","properties":{"a":{"type":"object","properties":{"b":{"type":"array","items":{"type":"object","properties":{"c":{"type":"integer"}}}}}}}}"#)
        #expect(schema.validate(#"{"a":{"b":[{"c":1},{"c":2}]}}"#).isValid)
        #expect(!schema.validate(#"{"a":{"b":[{"c":1},{"c":"x"}]}}"#).isValid)
    }
}
