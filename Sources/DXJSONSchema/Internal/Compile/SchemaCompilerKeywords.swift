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

    func requireString(_ value: JSONValue, keyword: String, at location: String) throws(JSONSchemaError) -> String {
        guard case .string(let string) = value else {
            throw .keywordValueMalformed(keyword: keyword, keywordLocation: location, expected: "a string")
        }
        return string.value
    }

    mutating func compileFormat(_ value: JSONValue, at location: String, into keywords: inout [CompiledKeyword]) throws(JSONSchemaError) {
        guard formatAssertion else { return }
        keywords.append(.format(FormatKind(try requireString(value, keyword: "format", at: location))))
    }

    mutating func compileUnevaluated(_ value: JSONValue, _ keyword: String, at location: String) throws(JSONSchemaError) -> Int {
        usesUnevaluated = true
        return try compileSubschema(value, at: location + "/" + keyword)
    }

    func unevaluatedLast(_ keywords: [CompiledKeyword]) -> [CompiledKeyword] {
        keywords.filter { !isUnevaluated($0) } + keywords.filter { isUnevaluated($0) }
    }

    func isUnevaluated(_ keyword: CompiledKeyword) -> Bool {
        switch keyword {
        case .unevaluatedProperties, .unevaluatedItems: true
        default: false
        }
    }

    func prefixItemCount(_ siblings: JSONObject) -> Int {
        guard case .found(.array(let elements)) = siblings.lookup("prefixItems") else { return 0 }
        return elements.count
    }

    func containsMinimum(_ siblings: JSONObject) -> Int {
        guard case .found(.number(let number)) = siblings.lookup("minContains"), case .found(let value) = nonNegativeIntValue(number) else {
            return 1
        }
        return value
    }

    func containsMaximum(_ siblings: JSONObject) -> ContainsMaximum {
        guard case .found(.number(let number)) = siblings.lookup("maxContains"), case .found(let value) = nonNegativeIntValue(number) else {
            return .unbounded
        }
        return .bounded(value)
    }

    func declaredPatterns(_ siblings: JSONObject, at location: String) throws(JSONSchemaError) -> [CompiledPattern] {
        guard case .found(.object(let patternObject)) = siblings.lookup("patternProperties") else { return [] }
        return try compilePatternList(patternObject, at: location)
    }

    func compilePatternList(_ object: JSONObject, at location: String) throws(JSONSchemaError) -> [CompiledPattern] {
        var patterns: [CompiledPattern] = []
        for member in object.members {
            patterns.append(try CompiledPattern(member.key.value, at: location + "/patternProperties"))
        }
        return patterns
    }

    mutating func compilePatternProperties(_ value: JSONValue, at location: String, into keywords: inout [CompiledKeyword]) throws(JSONSchemaError) {
        guard case .object(let object) = value else {
            throw .keywordValueMalformed(keyword: "patternProperties", keywordLocation: location, expected: "an object of schemas")
        }
        keywords.append(.patternProperties(try compilePatternSchemaList(object, at: location)))
    }

    mutating func compilePatternSchemaList(_ object: JSONObject, at location: String) throws(JSONSchemaError) -> [PatternSchema] {
        var list: [PatternSchema] = []
        for member in object.members {
            list.append(try compilePatternSchema(member, at: location))
        }
        return list
    }

    mutating func compilePatternSchema(_ member: JSONObject.Member, at location: String) throws(JSONSchemaError) -> PatternSchema {
        let pattern = try CompiledPattern(member.key.value, at: location + "/patternProperties/" + member.key.value)
        let index = try compileSubschema(member.value, at: location + "/patternProperties/" + member.key.value)
        return PatternSchema(pattern: pattern, schema: index)
    }

    func compileDependentRequired(_ value: JSONValue, at location: String) throws(JSONSchemaError) -> [DependentRequirement] {
        guard case .object(let object) = value else {
            throw .keywordValueMalformed(keyword: "dependentRequired", keywordLocation: location, expected: "an object of string arrays")
        }
        return try buildDependentRequirements(object, at: location)
    }

    func buildDependentRequirements(_ object: JSONObject, at location: String) throws(JSONSchemaError) -> [DependentRequirement] {
        var list: [DependentRequirement] = []
        for member in object.members {
            list.append(DependentRequirement(trigger: member.key.value, required: try requireStringArray(member.value, keyword: "dependentRequired", at: location)))
        }
        return list
    }

    mutating func compileDependentSchemas(_ value: JSONValue, at location: String) throws(JSONSchemaError) -> [DependentSchema] {
        guard case .object(let object) = value else {
            throw .keywordValueMalformed(keyword: "dependentSchemas", keywordLocation: location, expected: "an object of schemas")
        }
        return try buildDependentSchemas(object, at: location)
    }

    mutating func buildDependentSchemas(_ object: JSONObject, at location: String) throws(JSONSchemaError) -> [DependentSchema] {
        var list: [DependentSchema] = []
        for member in object.members {
            let index = try compileSubschema(member.value, at: location + "/dependentSchemas/" + member.key.value)
            list.append(DependentSchema(trigger: member.key.value, schema: index))
        }
        return list
    }
}
