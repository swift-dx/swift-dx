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

struct SchemaCompiler {

    var nodes: [Subschema] = []
    var pointerToNode: [String: Int] = [:]
    var anchorToNode: [String: Int] = [:]
    var idToNode: [String: Int] = [:]
    var currentBase: String = ""
    var currentResourceNode: Int = 0
    var referenceRequests: [ReferenceRequest] = []
    var referenceTargets: [Int] = []
    var rootIndex: Int = 0
    var formatAssertion: Bool = false
    var usesUnevaluated: Bool = false
    var usesDynamicScope: Bool = false
    var nodeAnchors: [Int: String] = [:]
    var dynamicResources: [Int: [String: Int]] = [:]
    var nodeResource: [Int: Int] = [:]
    var idToLocation: [String: String] = ["": ""]
    var activeVocabularies: Set<SchemaVocabulary> = SchemaVocabulary.all

    static func compile(_ schema: JSONValue, formatAssertion: Bool, resources: [ResourceDocument]) throws(JSONSchemaError) -> CompiledDocument {
        var compiler = SchemaCompiler()
        compiler.formatAssertion = formatAssertion
        compiler.activeVocabularies = try compiler.resolveActiveVocabularies(schema, resources)
        compiler.rootIndex = try compiler.compileSubschema(schema, at: "")
        compiler.activeVocabularies = SchemaVocabulary.all
        try compiler.compileResources(resources)
        try compiler.linkReferences()
        return CompiledDocument(
            nodes: compiler.nodes,
            root: compiler.rootIndex,
            refTargets: compiler.referenceTargets,
            usesUnevaluated: compiler.usesUnevaluated,
            usesDynamicScope: compiler.usesDynamicScope,
            nodeAnchors: compiler.nodeAnchors,
            dynamicResources: compiler.dynamicResources,
            nodeResource: compiler.nodeResource
        )
    }

    mutating func appendNode(_ node: Subschema) -> Int {
        nodes.append(node)
        return nodes.count - 1
    }

    mutating func registerLeaf(_ node: Subschema, at location: String) -> Int {
        let index = appendNode(node)
        pointerToNode[location] = index
        nodeResource[index] = currentResourceNode
        return index
    }

    mutating func reserveNode(at location: String) -> Int {
        let index = appendNode(.always)
        pointerToNode[location] = index
        return index
    }

    mutating func compileSubschema(_ schema: JSONValue, at location: String) throws(JSONSchemaError) -> Int {
        switch schema {
        case .bool(let allowed): return registerLeaf(allowed ? .always : .never, at: location)
        case .object(let object): return try compileObject(object, at: location)
        default: throw .schemaNotObjectOrBoolean(keywordLocation: location)
        }
    }

    mutating func compileObject(_ object: JSONObject, at location: String) throws(JSONSchemaError) -> Int {
        let index = reserveNode(at: location)
        let savedBase = currentBase
        let savedResourceNode = currentResourceNode
        applyIdentifier(object, node: index, at: location)
        nodeResource[index] = currentResourceNode
        var keywords: [CompiledKeyword] = []
        for member in object.members {
            try compileKeyword(member.key, value: member.value, siblings: object, node: index, at: location, into: &keywords)
        }
        currentBase = savedBase
        currentResourceNode = savedResourceNode
        nodes[index] = .keywords(unevaluatedLast(keywords))
        return index
    }

    mutating func compileKeyword(_ key: String, value: JSONValue, siblings: JSONObject, node: Int, at location: String, into keywords: inout [CompiledKeyword]) throws(JSONSchemaError) {
        guard vocabularyActive(for: key) else { return }
        switch key {
        case "$ref": keywords.append(.reference(slot: try registerReferenceRequest(value, keyword: key, at: location)))
        case "$dynamicRef": try compileDynamicRef(value, keyword: key, at: location, into: &keywords)
        case "$defs": try compileDefinitions(value, at: location)
        case "$anchor": try registerAnchor(value, node: node, at: location)
        case "$dynamicAnchor": try registerDynamicAnchor(value, node: node, at: location)
        case "type": keywords.append(.type(try buildTypeConstraint(value, at: location)))
        case "enum": keywords.append(.enumValues(try requireArray(value, keyword: key, at: location)))
        case "const": keywords.append(.constValue(value))
        case "multipleOf": keywords.append(.multipleOf(try requireNumber(value, keyword: key, at: location)))
        case "maximum": keywords.append(.maximum(try requireNumber(value, keyword: key, at: location)))
        case "exclusiveMaximum": keywords.append(.exclusiveMaximum(try requireNumber(value, keyword: key, at: location)))
        case "minimum": keywords.append(.minimum(try requireNumber(value, keyword: key, at: location)))
        case "exclusiveMinimum": keywords.append(.exclusiveMinimum(try requireNumber(value, keyword: key, at: location)))
        case "maxLength": keywords.append(.maxLength(try requireNonNegativeInt(value, keyword: key, at: location)))
        case "minLength": keywords.append(.minLength(try requireNonNegativeInt(value, keyword: key, at: location)))
        case "pattern": keywords.append(.pattern(try CompiledPattern(requireString(value, keyword: key, at: location), at: location + "/pattern")))
        case "format": try compileFormat(value, at: location, into: &keywords)
        case "maxItems": keywords.append(.maxItems(try requireNonNegativeInt(value, keyword: key, at: location)))
        case "minItems": keywords.append(.minItems(try requireNonNegativeInt(value, keyword: key, at: location)))
        case "maxProperties": keywords.append(.maxProperties(try requireNonNegativeInt(value, keyword: key, at: location)))
        case "minProperties": keywords.append(.minProperties(try requireNonNegativeInt(value, keyword: key, at: location)))
        case "uniqueItems": try compileUniqueItems(value, at: location, into: &keywords)
        case "required": keywords.append(.required(try requireStringArray(value, keyword: key, at: location)))
        case "properties": try compileProperties(value, at: location, into: &keywords)
        case "patternProperties": try compilePatternProperties(value, at: location, into: &keywords)
        case "propertyNames": keywords.append(.propertyNames(try compileSubschema(value, at: location + "/propertyNames")))
        case "dependentRequired": keywords.append(.dependentRequired(try compileDependentRequired(value, at: location)))
        case "dependentSchemas": keywords.append(.dependentSchemas(try compileDependentSchemas(value, at: location)))
        case "prefixItems": keywords.append(.prefixItems(try compileSubschemaArray(value, keyword: key, at: location)))
        case "items": keywords.append(.items(from: prefixItemCount(siblings), schema: try compileSubschema(value, at: location + "/items")))
        case "contains": keywords.append(.contains(schema: try compileSubschema(value, at: location + "/contains"), minimum: containsMinimum(siblings), maximum: containsMaximum(siblings)))
        case "unevaluatedProperties": keywords.append(.unevaluatedProperties(try compileUnevaluated(value, "unevaluatedProperties", at: location)))
        case "unevaluatedItems": keywords.append(.unevaluatedItems(try compileUnevaluated(value, "unevaluatedItems", at: location)))
        case "additionalProperties": try compileAdditionalProperties(value, siblings: siblings, at: location, into: &keywords)
        case "allOf": keywords.append(.allOf(try compileSubschemaArray(value, keyword: key, at: location)))
        case "anyOf": keywords.append(.anyOf(try compileSubschemaArray(value, keyword: key, at: location)))
        case "oneOf": keywords.append(.oneOf(try compileSubschemaArray(value, keyword: key, at: location)))
        case "not": keywords.append(.not(try compileSubschema(value, at: location + "/not")))
        case "if": try compileIfThenElse(condition: value, siblings: siblings, at: location, into: &keywords)
        case "then": try compileInertSlot(value, siblings: siblings, keyword: "then", at: location)
        case "else": try compileInertSlot(value, siblings: siblings, keyword: "else", at: location)
        default: break
        }
    }
}
