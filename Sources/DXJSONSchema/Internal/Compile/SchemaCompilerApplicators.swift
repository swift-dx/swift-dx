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

    mutating func compileUniqueItems(_ value: JSONValue, at location: String, into keywords: inout [CompiledKeyword]) throws(JSONSchemaError) {
        guard case .bool(let flag) = value else {
            throw .keywordValueMalformed(keyword: "uniqueItems", keywordLocation: location, expected: "a boolean")
        }
        appendUniqueItemsIfNeeded(flag, into: &keywords)
    }

    func appendUniqueItemsIfNeeded(_ flag: Bool, into keywords: inout [CompiledKeyword]) {
        guard flag else { return }
        keywords.append(.uniqueItems)
    }

    mutating func compileProperties(_ value: JSONValue, at location: String, into keywords: inout [CompiledKeyword]) throws(JSONSchemaError) {
        guard case .object(let object) = value else {
            throw .keywordValueMalformed(keyword: "properties", keywordLocation: location, expected: "an object of schemas")
        }
        keywords.append(.properties(try compilePropertyList(object, at: location)))
    }

    mutating func compilePropertyList(_ object: JSONObject, at location: String) throws(JSONSchemaError) -> [PropertySchema] {
        var list: [PropertySchema] = []
        for member in object.members {
            let index = try compileSubschema(member.value, at: location + "/properties/" + member.key)
            list.append(PropertySchema(name: member.key, schema: index))
        }
        return list
    }

    mutating func compileAdditionalProperties(_ value: JSONValue, siblings: JSONObject, at location: String, into keywords: inout [CompiledKeyword]) throws(JSONSchemaError) {
        let declared = declaredPropertyNames(siblings)
        let patterns = try declaredPatterns(siblings, at: location)
        let index = try compileSubschema(value, at: location + "/additionalProperties")
        keywords.append(.additionalProperties(declared: declared, patterns: patterns, schema: index))
    }

    func declaredPropertyNames(_ siblings: JSONObject) -> Set<String> {
        guard case .found(.object(let properties)) = siblings.lookup("properties") else { return [] }
        return Set(properties.keys)
    }

    mutating func compileSubschemaArray(_ value: JSONValue, keyword: String, at location: String) throws(JSONSchemaError) -> [Int] {
        guard case .array(let elements) = value, !elements.isEmpty else {
            throw .keywordValueMalformed(keyword: keyword, keywordLocation: location, expected: "a non-empty array of schemas")
        }
        return try compileSubschemaElements(elements, keyword: keyword, at: location)
    }

    mutating func compileSubschemaElements(_ elements: [JSONValue], keyword: String, at location: String) throws(JSONSchemaError) -> [Int] {
        var indices: [Int] = []
        for offset in elements.indices {
            indices.append(try compileSubschema(elements[offset], at: location + "/" + keyword + "/" + String(offset)))
        }
        return indices
    }

    mutating func compileIfThenElse(condition value: JSONValue, siblings: JSONObject, at location: String, into keywords: inout [CompiledKeyword]) throws(JSONSchemaError) {
        let conditionIndex = try compileSubschema(value, at: location + "/if")
        let success = try compileSlot(siblings, keyword: "then", at: location)
        let failure = try compileSlot(siblings, keyword: "else", at: location)
        keywords.append(.ifThenElse(condition: conditionIndex, success: success, failure: failure))
    }

    mutating func compileSlot(_ siblings: JSONObject, keyword: String, at location: String) throws(JSONSchemaError) -> SubschemaSlot {
        guard case .found(let schema) = siblings.lookup(keyword) else { return .absent }
        return .present(try compileSubschema(schema, at: location + "/" + keyword))
    }

    mutating func compileInertSlot(_ value: JSONValue, siblings: JSONObject, keyword: String, at location: String) throws(JSONSchemaError) {
        guard case .notFound = siblings.lookup("if") else { return }
        _ = try compileSubschema(value, at: location + "/" + keyword)
    }
}
