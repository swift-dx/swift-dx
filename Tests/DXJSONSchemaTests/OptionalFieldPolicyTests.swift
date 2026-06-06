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
struct OptionalFieldPolicyTests {

    static let strictObject = ##"{"type":"object","additionalProperties":false,"required":["name"],"properties":{"name":{"type":"string"}}}"##
    static let optionalProperty = ##"{"type":"object","additionalProperties":false,"properties":{"name":{"type":"string"}}}"##
    static let openObject = ##"{"type":"object","required":["name"],"properties":{"name":{"type":"string"}}}"##
    static let bareObjectType = ##"{"type":"object"}"##
    static let nullableUnion = ##"{"type":["string","null"]}"##
    static let nullType = ##"{"type":"null"}"##
    static let scalar = ##"{"type":"string","minLength":1}"##
    static let nestedOpenObject = ##"{"type":"object","additionalProperties":false,"required":["inner"],"properties":{"inner":{"type":"object","properties":{"x":{"type":"string"}}}}}"##
    static let patternPropsObject = ##"{"type":"object","additionalProperties":false,"required":["a"],"properties":{"a":{"type":"string"}},"patternProperties":{"^z":{"type":"string"}}}"##
    static let requiredOnlyObject = ##"{"required":["a"]}"##
    static let minPropertiesObject = ##"{"minProperties":1}"##
    static let unevaluatedClosedObject = ##"{"type":"object","unevaluatedProperties":false,"required":["a"],"properties":{"a":{"type":"string"}}}"##
    static let optionalInAllOf = ##"{"allOf":[{"type":"object","additionalProperties":false,"properties":{"a":{"type":"string"}}}]}"##
    static let nullableInDefs = ##"{"type":"object","additionalProperties":false,"required":["a"],"properties":{"a":{"type":"string"}},"$defs":{"x":{"type":["string","null"]}}}"##

    @Test
    func allowedAcceptsOptionalPropertyByDefault() throws {
        let schema = try JSONSchema.compile(Self.optionalProperty)
        #expect(schema.validate(##"{}"##).isValid)
    }

    @Test
    func forbiddenAcceptsFullyStrictObject() throws {
        let schema = try JSONSchema.compile(Self.strictObject, optionalFields: .forbidden)
        #expect(schema.validate(##"{"name":"x"}"##).isValid)
        #expect(!schema.validate(##"{}"##).isValid)
    }

    @Test
    func forbiddenRejectsOptionalProperty() {
        do {
            _ = try JSONSchema.compile(Self.optionalProperty, optionalFields: .forbidden)
            Issue.record("expected a thrown error")
        } catch {
            #expect(error == .optionalPropertyForbidden(keywordLocation: "", property: "name"))
        }
    }

    @Test
    func forbiddenRejectsOpenObject() {
        do {
            _ = try JSONSchema.compile(Self.openObject, optionalFields: .forbidden)
            Issue.record("expected a thrown error")
        } catch {
            #expect(error == .openObjectForbidden(keywordLocation: ""))
        }
    }

    @Test
    func forbiddenRejectsBareObjectType() {
        do {
            _ = try JSONSchema.compile(Self.bareObjectType, optionalFields: .forbidden)
            Issue.record("expected a thrown error")
        } catch {
            #expect(error == .openObjectForbidden(keywordLocation: ""))
        }
    }

    @Test
    func forbiddenRejectsNullableUnion() {
        do {
            _ = try JSONSchema.compile(Self.nullableUnion, optionalFields: .forbidden)
            Issue.record("expected a thrown error")
        } catch {
            #expect(error == .nullableTypeForbidden(keywordLocation: ""))
        }
    }

    @Test
    func forbiddenRejectsNullType() {
        do {
            _ = try JSONSchema.compile(Self.nullType, optionalFields: .forbidden)
            Issue.record("expected a thrown error")
        } catch {
            #expect(error == .nullableTypeForbidden(keywordLocation: ""))
        }
    }

    @Test
    func forbiddenAllowsScalarSchema() throws {
        let schema = try JSONSchema.compile(Self.scalar, optionalFields: .forbidden)
        #expect(schema.validate(##""ok""##).isValid)
    }

    @Test
    func forbiddenAllowsBooleanSchema() throws {
        let schema = try JSONSchema.compile("true", optionalFields: .forbidden)
        #expect(schema.validate(##"{}"##).isValid)
    }

    @Test
    func forbiddenRecursesIntoNestedSubschemas() {
        do {
            _ = try JSONSchema.compile(Self.nestedOpenObject, optionalFields: .forbidden)
            Issue.record("expected a thrown error")
        } catch {
            #expect(error == .openObjectForbidden(keywordLocation: "/properties/inner"))
        }
    }

    @Test
    func allowedAcceptsOpenObject() throws {
        let schema = try JSONSchema.compile(Self.openObject, optionalFields: .allowed)
        #expect(schema.validate(##"{"name":"x","extra":1}"##).isValid)
    }

    @Test
    func allowedAcceptsNullableUnion() throws {
        let schema = try JSONSchema.compile(Self.nullableUnion, optionalFields: .allowed)
        #expect(schema.validate("null").isValid)
    }

    @Test
    func forbiddenRejectsPatternPropertiesEvenWhenAdditionalPropertiesFalse() {
        do {
            _ = try JSONSchema.compile(Self.patternPropsObject, optionalFields: .forbidden)
            Issue.record("expected a thrown error")
        } catch {
            #expect(error == .openObjectForbidden(keywordLocation: ""))
        }
    }

    @Test
    func forbiddenRejectsRequiredOnlyObject() {
        do {
            _ = try JSONSchema.compile(Self.requiredOnlyObject, optionalFields: .forbidden)
            Issue.record("expected a thrown error")
        } catch {
            #expect(error == .openObjectForbidden(keywordLocation: ""))
        }
    }

    @Test
    func forbiddenRejectsMinPropertiesObject() {
        do {
            _ = try JSONSchema.compile(Self.minPropertiesObject, optionalFields: .forbidden)
            Issue.record("expected a thrown error")
        } catch {
            #expect(error == .openObjectForbidden(keywordLocation: ""))
        }
    }

    @Test
    func forbiddenAcceptsUnevaluatedPropertiesFalse() throws {
        let schema = try JSONSchema.compile(Self.unevaluatedClosedObject, optionalFields: .forbidden)
        #expect(schema.validate(##"{"a":"x"}"##).isValid)
        #expect(!schema.validate(##"{"a":"x","b":1}"##).isValid)
    }

    @Test
    func forbiddenRecursesIntoAllOf() {
        do {
            _ = try JSONSchema.compile(Self.optionalInAllOf, optionalFields: .forbidden)
            Issue.record("expected a thrown error")
        } catch {
            #expect(error == .optionalPropertyForbidden(keywordLocation: "/allOf/0", property: "a"))
        }
    }

    @Test
    func forbiddenRecursesIntoDefs() {
        do {
            _ = try JSONSchema.compile(Self.nullableInDefs, optionalFields: .forbidden)
            Issue.record("expected a thrown error")
        } catch {
            #expect(error == .nullableTypeForbidden(keywordLocation: "/$defs/x"))
        }
    }

    @Test
    func registryApplyForbiddenAcceptsStrictSchema() throws {
        let registry = SchemaRegistry()
        try registry.apply([SchemaEnvelope(type: "person", schema: Self.strictObject)], optionalFields: .forbidden)
        #expect(registry.validate(##"{"name":"x"}"##, type: "person").isValid)
    }

    @Test
    func registryApplyForbiddenRejectsOptionalProperty() {
        let registry = SchemaRegistry()
        do {
            try registry.apply([SchemaEnvelope(type: "person", schema: Self.optionalProperty)], optionalFields: .forbidden)
            Issue.record("expected a thrown error")
        } catch {
            #expect(error == .optionalPropertyForbidden(keywordLocation: "", property: "name"))
        }
        #expect(registry.registeredTypes.isEmpty)
    }

    @Test
    func registryMergeForbiddenLeavesExistingTypesUntouched() throws {
        let registry = SchemaRegistry()
        try registry.apply([SchemaEnvelope(type: "kept", schema: Self.strictObject)], optionalFields: .forbidden)
        let before = registry.generation

        do {
            try registry.merge([SchemaEnvelope(type: "bad", schema: Self.openObject)], optionalFields: .forbidden)
            Issue.record("expected a thrown error")
        } catch {
            #expect(error == .openObjectForbidden(keywordLocation: ""))
        }

        #expect(registry.registeredTypes == ["kept"])
        #expect(registry.generation.value == before.value)
    }

    @Test
    func descriptionsAreSelfContained() {
        #expect(JSONSchemaError.optionalPropertyForbidden(keywordLocation: "/a", property: "name").description.contains("'name'"))
        #expect(JSONSchemaError.nullableTypeForbidden(keywordLocation: "/a").description.contains("null"))
        #expect(JSONSchemaError.openObjectForbidden(keywordLocation: "/a").description.contains("additionalProperties"))
    }
}
