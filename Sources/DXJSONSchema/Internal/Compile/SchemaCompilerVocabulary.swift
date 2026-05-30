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

import DXCore

extension SchemaCompiler {

    static let standardDialect = "https://json-schema.org/draft/2020-12/schema"
    static let vocabularyPrefix = "https://json-schema.org/draft/2020-12/vocab/"

    func resolveActiveVocabularies(_ schema: JSONValue, _ resources: [ResourceDocument]) throws(JSONSchemaError) -> Set<SchemaVocabulary> {
        guard case .object(let object) = schema, case .found(.string(let dialect)) = object.lookup("$schema") else { return SchemaVocabulary.all }
        guard dialect.value != Self.standardDialect else { return SchemaVocabulary.all }
        return try vocabulariesFromMetaschema(dialect.value, resources)
    }

    func vocabulariesFromMetaschema(_ dialect: String, _ resources: [ResourceDocument]) throws(JSONSchemaError) -> Set<SchemaVocabulary> {
        guard case .found(let metaschema) = findResource(dialect, resources) else { return SchemaVocabulary.all }
        guard case .object(let object) = metaschema, case .found(.object(let declared)) = object.lookup("$vocabulary") else { return SchemaVocabulary.all }
        return try activeSet(declared)
    }

    func findResource(_ uri: String, _ resources: [ResourceDocument]) -> Lookup<JSONValue> {
        for resource in resources where resource.uri == uri {
            return .found(resource.value)
        }
        return .notFound
    }

    func activeSet(_ declared: JSONObject) throws(JSONSchemaError) -> Set<SchemaVocabulary> {
        var active: Set<SchemaVocabulary> = [.core]
        for member in declared.members {
            try includeVocabulary(member, into: &active)
        }
        return active
    }

    func includeVocabulary(_ member: JSONObject.Member, into active: inout Set<SchemaVocabulary>) throws(JSONSchemaError) {
        switch knownVocabulary(member.key.value) {
        case .found(let vocabulary): active.insert(vocabulary)
        case .notFound: try rejectIfRequired(member)
        }
    }

    func rejectIfRequired(_ member: JSONObject.Member) throws(JSONSchemaError) {
        guard case .bool(true) = member.value else { return }
        throw .unknownRequiredVocabulary(uri: member.key.value)
    }

    func knownVocabulary(_ uri: String) -> Lookup<SchemaVocabulary> {
        switch uri {
        case Self.vocabularyPrefix + "core": .found(.core)
        case Self.vocabularyPrefix + "applicator": .found(.applicator)
        case Self.vocabularyPrefix + "unevaluated": .found(.unevaluated)
        case Self.vocabularyPrefix + "validation": .found(.validation)
        case Self.vocabularyPrefix + "meta-data": .found(.metaData)
        case Self.vocabularyPrefix + "format-annotation": .found(.formatAnnotation)
        case Self.vocabularyPrefix + "content": .found(.content)
        default: .notFound
        }
    }

    func vocabularyActive(for keyword: String) -> Bool {
        activeVocabularies.contains(vocabulary(for: keyword))
    }

    func vocabulary(for keyword: String) -> SchemaVocabulary {
        switch keyword {
        case "type", "const", "enum", "multipleOf", "maximum", "exclusiveMaximum", "minimum", "exclusiveMinimum", "maxLength", "minLength", "pattern", "maxItems", "minItems", "maxContains", "minContains", "uniqueItems", "maxProperties", "minProperties", "required", "dependentRequired": .validation
        case "prefixItems", "items", "contains", "additionalProperties", "properties", "patternProperties", "dependentSchemas", "propertyNames", "allOf", "anyOf", "oneOf", "not", "if", "then", "else": .applicator
        case "unevaluatedItems", "unevaluatedProperties": .unevaluated
        case "format": .formatAnnotation
        default: .core
        }
    }
}
