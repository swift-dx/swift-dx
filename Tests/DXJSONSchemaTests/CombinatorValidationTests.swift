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
struct CombinatorValidationTests {

    @Test
    func allOfRequiresEveryBranch() throws {
        let schema = try JSONSchema.compile(#"{"allOf":[{"type":"integer"},{"minimum":5}]}"#)
        #expect(schema.validate("7").isValid)
        #expect(!schema.validate("3").isValid)
        #expect(!schema.validate(#""x""#).isValid)
    }

    @Test
    func anyOfRequiresAtLeastOneBranch() throws {
        let schema = try JSONSchema.compile(#"{"anyOf":[{"type":"string"},{"type":"integer"}]}"#)
        #expect(schema.validate(#""x""#).isValid)
        #expect(schema.validate("7").isValid)
        #expect(!schema.validate("true").isValid)
    }

    @Test
    func oneOfRequiresExactlyOneBranch() throws {
        let schema = try JSONSchema.compile(#"{"oneOf":[{"multipleOf":3},{"multipleOf":5}]}"#)
        #expect(schema.validate("9").isValid)
        #expect(schema.validate("10").isValid)
        #expect(!schema.validate("15").isValid)
        #expect(!schema.validate("7").isValid)
    }

    @Test
    func notInvertsValidation() throws {
        let schema = try JSONSchema.compile(#"{"not":{"type":"string"}}"#)
        #expect(schema.validate("5").isValid)
        #expect(!schema.validate(#""x""#).isValid)
    }

    @Test
    func ifThenAppliesThenWhenConditionMatches() throws {
        let schema = try JSONSchema.compile(#"{"if":{"type":"integer"},"then":{"minimum":10}}"#)
        #expect(schema.validate("15").isValid)
        #expect(!schema.validate("5").isValid)
        #expect(schema.validate(#""x""#).isValid)
    }

    @Test
    func ifElseAppliesElseWhenConditionFails() throws {
        let schema = try JSONSchema.compile(#"{"if":{"type":"integer"},"then":{"minimum":10},"else":{"type":"string"}}"#)
        #expect(schema.validate("15").isValid)
        #expect(schema.validate(#""x""#).isValid)
        #expect(!schema.validate("true").isValid)
    }

    @Test
    func collectsViolationsFromMultipleKeywords() throws {
        let schema = try JSONSchema.compile(#"{"type":"object","required":["a"],"properties":{"b":{"type":"integer"}}}"#)
        let result = schema.validate(#"{"b":"notInt"}"#)
        #expect(result.violations.count >= 2)
    }

    @Test
    func malformedInstanceReportsParseFailure() throws {
        let schema = try JSONSchema.compile(#"{"type":"object"}"#)
        let result = schema.validate("{not json")
        guard case .instanceNotValidJSON = result else {
            Issue.record("expected instanceNotValidJSON, got \(result)")
            return
        }
        #expect(!result.isValid)
    }

    @Test
    func malformedSchemaThrows() {
        #expect(throws: JSONSchemaError.self) {
            try JSONSchema.compile(#"{"type":123}"#)
        }
    }

    @Test
    func nonObjectSchemaThrows() {
        #expect(throws: JSONSchemaError.self) {
            try JSONSchema.compile("42")
        }
    }
}
