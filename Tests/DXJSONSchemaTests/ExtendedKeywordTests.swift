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
struct ExtendedKeywordTests {

    @Test
    func patternMatchesString() throws {
        let schema = try JSONSchema.compile(#"{"type":"string","pattern":"^a.*z$"}"#)
        #expect(schema.validate(#""abcz""#).isValid)
        #expect(!schema.validate(#""abc""#).isValid)
    }

    @Test
    func patternIsUnanchoredMatch() throws {
        let schema = try JSONSchema.compile(#"{"pattern":"[0-9]+"}"#)
        #expect(schema.validate(#""abc123def""#).isValid)
        #expect(!schema.validate(#""abcdef""#).isValid)
    }

    @Test
    func patternPropertiesValidatesMatchingKeys() throws {
        let schema = try JSONSchema.compile(#"{"patternProperties":{"^x":{"type":"integer"}}}"#)
        #expect(schema.validate(#"{"x1":5}"#).isValid)
        #expect(!schema.validate(#"{"x1":"no"}"#).isValid)
        #expect(schema.validate(#"{"y1":"anything"}"#).isValid)
    }

    @Test
    func additionalPropertiesExcludesPatternMatches() throws {
        let schema = try JSONSchema.compile(#"{"patternProperties":{"^x":{"type":"integer"}},"additionalProperties":false}"#)
        #expect(schema.validate(#"{"x1":5}"#).isValid)
        #expect(!schema.validate(#"{"y1":5}"#).isValid)
    }

    @Test
    func propertyNamesConstrainsKeys() throws {
        let schema = try JSONSchema.compile(#"{"propertyNames":{"pattern":"^[a-z]+$"}}"#)
        #expect(schema.validate(#"{"abc":1}"#).isValid)
        #expect(!schema.validate(#"{"AB":1}"#).isValid)
    }

    @Test
    func dependentRequiredEnforcesCompanions() throws {
        let schema = try JSONSchema.compile(#"{"dependentRequired":{"card":["billing"]}}"#)
        #expect(schema.validate(#"{"card":1,"billing":"x"}"#).isValid)
        #expect(!schema.validate(#"{"card":1}"#).isValid)
        #expect(schema.validate(#"{"name":1}"#).isValid)
    }

    @Test
    func dependentSchemasAppliedWhenTriggerPresent() throws {
        let schema = try JSONSchema.compile(#"{"dependentSchemas":{"card":{"required":["billing"]}}}"#)
        #expect(schema.validate(#"{"card":1,"billing":1}"#).isValid)
        #expect(!schema.validate(#"{"card":1}"#).isValid)
        #expect(schema.validate("{}").isValid)
    }

    @Test
    func prefixItemsValidatePositionally() throws {
        let schema = try JSONSchema.compile(#"{"prefixItems":[{"type":"string"},{"type":"integer"}]}"#)
        #expect(schema.validate(#"["a",1]"#).isValid)
        #expect(!schema.validate(#"[1,1]"#).isValid)
        #expect(schema.validate(#"["a"]"#).isValid)
    }

    @Test
    func itemsAppliesAfterPrefix() throws {
        let schema = try JSONSchema.compile(#"{"prefixItems":[{"type":"string"},{"type":"integer"}],"items":{"type":"boolean"}}"#)
        #expect(schema.validate(#"["a",1,true,false]"#).isValid)
        #expect(!schema.validate(#"["a",1,1]"#).isValid)
        #expect(schema.validate(#"["a",1]"#).isValid)
    }

    @Test
    func containsRequiresAtLeastOneMatch() throws {
        let schema = try JSONSchema.compile(#"{"contains":{"type":"integer"}}"#)
        #expect(schema.validate(#"[1,"a"]"#).isValid)
        #expect(!schema.validate(#"["a","b"]"#).isValid)
        #expect(!schema.validate("[]").isValid)
    }

    @Test
    func minAndMaxContainsBoundMatchCount() throws {
        let schema = try JSONSchema.compile(#"{"contains":{"const":1},"minContains":2,"maxContains":3}"#)
        #expect(schema.validate("[1,1]").isValid)
        #expect(schema.validate("[1,1,1]").isValid)
        #expect(!schema.validate("[1]").isValid)
        #expect(!schema.validate("[1,1,1,1]").isValid)
    }

    @Test
    func minContainsZeroAllowsNoMatches() throws {
        let schema = try JSONSchema.compile(#"{"contains":{"type":"integer"},"minContains":0}"#)
        #expect(schema.validate("[]").isValid)
        #expect(schema.validate(#"["a"]"#).isValid)
    }
}
