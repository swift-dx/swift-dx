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
struct SchemaRegistryTests {

    static let intSchema = ##"{"type":"integer"}"##
    static let stringSchema = ##"{"type":"string"}"##

    @Test
    func applyThenValidateByType() throws {
        let registry = SchemaRegistry()
        try registry.apply([SchemaEnvelope(type: "number", schema: Self.intSchema)])
        #expect(registry.validate("5", type: "number").isValid)
        #expect(!registry.validate(##""x""##, type: "number").isValid)
    }

    @Test
    func multipleRevisionsOfTypeAcceptIfAny() throws {
        let registry = SchemaRegistry()
        try registry.apply([
            SchemaEnvelope(type: "order", schema: Self.intSchema),
            SchemaEnvelope(type: "order", schema: Self.stringSchema),
        ])
        #expect(registry.revisionCount(ofType: "order") == 2)
        #expect(registry.validate("5", type: "order").isValid)
        #expect(registry.validate(##""x""##, type: "order").isValid)
        #expect(!registry.validate("true", type: "order").isValid)
    }

    @Test
    func unknownTypeReportsNotRegistered() {
        let registry = SchemaRegistry()
        guard case .schemaNotRegistered(let type) = registry.validate("5", type: "nope") else {
            Issue.record("expected schemaNotRegistered")
            return
        }
        #expect(type == "nope")
    }

    @Test
    func presentTypeWithNoAcceptingRevisionIsInvalid() throws {
        let registry = SchemaRegistry()
        try registry.apply([SchemaEnvelope(type: "t", schema: Self.intSchema)])
        let result = registry.validate(##""x""##, type: "t")
        #expect(!result.isValid)
        guard case .invalid = result else {
            Issue.record("expected invalid")
            return
        }
    }

    @Test
    func emptyTypeRejectedAtApply() {
        let registry = SchemaRegistry()
        #expect(throws: JSONSchemaError.invalidSchemaType) {
            try registry.apply([SchemaEnvelope(type: "", schema: Self.intSchema)])
        }
    }

    @Test
    func structurallyInvalidSchemaRejectedAtApply() {
        let registry = SchemaRegistry()
        #expect(throws: JSONSchemaError.self) {
            try registry.apply([SchemaEnvelope(type: "t", schema: ##"{"$id":"id-with#fragment"}"##)])
        }
        #expect(registry.registeredTypes.isEmpty)
    }

    @Test
    func malformedSchemaRejectedAtApply() {
        let registry = SchemaRegistry()
        #expect(throws: JSONSchemaError.self) {
            try registry.apply([SchemaEnvelope(type: "t", schema: ##"{"type":"##)])
        }
    }

    @Test
    func malformedPayloadReportsNotValidJSON() throws {
        let registry = SchemaRegistry()
        try registry.apply([SchemaEnvelope(type: "t", schema: Self.intSchema)])
        guard case .instanceNotValidJSON = registry.validate("{", type: "t") else {
            Issue.record("expected instanceNotValidJSON")
            return
        }
    }

    @Test
    func generationAdvancesOnApply() throws {
        let registry = SchemaRegistry()
        let before = registry.generation
        try registry.apply([SchemaEnvelope(type: "g", schema: Self.intSchema)])
        #expect(registry.generation.value > before.value)
    }

    @Test
    func registeredTypesListsAll() throws {
        let registry = SchemaRegistry()
        try registry.apply([
            SchemaEnvelope(type: "a", schema: Self.intSchema),
            SchemaEnvelope(type: "b", schema: Self.stringSchema),
        ])
        #expect(Set(registry.registeredTypes) == ["a", "b"])
    }
}
