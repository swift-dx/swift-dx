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

    static let objectShapingKeywords = [
        "properties",
        "patternProperties",
        "additionalProperties",
        "propertyNames",
        "unevaluatedProperties",
        "minProperties",
        "maxProperties",
        "required",
        "dependentRequired",
        "dependentSchemas",
    ]

    func enforceOptionalFieldPolicy(_ object: JSONObject, at location: String) throws(JSONSchemaError) {
        guard optionalFields == .forbidden else { return }
        try requireNoNullableType(object, at: location)
        try requireClosedObject(object, at: location)
        try requireAllPropertiesRequired(object, at: location)
    }

    func requireNoNullableType(_ object: JSONObject, at location: String) throws(JSONSchemaError) {
        guard case .found(let typeValue) = object.lookup("type") else { return }
        guard typeNamesContain(typeValue, "null") else { return }
        throw .nullableTypeForbidden(keywordLocation: location)
    }

    func requireClosedObject(_ object: JSONObject, at location: String) throws(JSONSchemaError) {
        guard schemaDescribesObject(object) else { return }
        try rejectPatternProperties(object, at: location)
        guard objectIsClosed(object) else {
            throw .openObjectForbidden(keywordLocation: location)
        }
    }

    func rejectPatternProperties(_ object: JSONObject, at location: String) throws(JSONSchemaError) {
        guard object.contains("patternProperties") else { return }
        throw .openObjectForbidden(keywordLocation: location)
    }

    func requireAllPropertiesRequired(_ object: JSONObject, at location: String) throws(JSONSchemaError) {
        guard case .found(.object(let properties)) = object.lookup("properties") else { return }
        try requireEveryPropertyListed(properties, required: requiredNameSet(object), at: location)
    }

    func requireEveryPropertyListed(_ properties: JSONObject, required: Set<String>, at location: String) throws(JSONSchemaError) {
        for member in properties.members {
            try requireListed(member.key.value, required: required, at: location)
        }
    }

    func requireListed(_ name: String, required: Set<String>, at location: String) throws(JSONSchemaError) {
        guard required.contains(name) else {
            throw .optionalPropertyForbidden(keywordLocation: location, property: name)
        }
    }

    func schemaDescribesObject(_ object: JSONObject) -> Bool {
        if typeIncludesObject(object) { return true }
        return declaresObjectKeyword(object)
    }

    func typeIncludesObject(_ object: JSONObject) -> Bool {
        guard case .found(let typeValue) = object.lookup("type") else { return false }
        return typeNamesContain(typeValue, "object")
    }

    func declaresObjectKeyword(_ object: JSONObject) -> Bool {
        for keyword in Self.objectShapingKeywords where object.contains(keyword) {
            return true
        }
        return false
    }

    func objectIsClosed(_ object: JSONObject) -> Bool {
        if keywordIsFalse(object, "additionalProperties") { return true }
        return keywordIsFalse(object, "unevaluatedProperties")
    }

    func keywordIsFalse(_ object: JSONObject, _ keyword: String) -> Bool {
        guard case .found(.bool(false)) = object.lookup(keyword) else { return false }
        return true
    }

    func requiredNameSet(_ object: JSONObject) -> Set<String> {
        guard case .found(.array(let names)) = object.lookup("required") else { return [] }
        return stringSet(names)
    }

    func stringSet(_ values: [JSONValue]) -> Set<String> {
        var names: Set<String> = []
        for value in values {
            insertStringName(value, into: &names)
        }
        return names
    }

    func insertStringName(_ value: JSONValue, into names: inout Set<String>) {
        guard case .string(let string) = value else { return }
        names.insert(string.value)
    }

    func typeNamesContain(_ value: JSONValue, _ name: String) -> Bool {
        switch value {
        case .string(let string): return string.equalsString(name)
        case .array(let elements): return elements.contains { typeElementEquals($0, name) }
        default: return false
        }
    }

    func typeElementEquals(_ value: JSONValue, _ name: String) -> Bool {
        guard case .string(let string) = value else { return false }
        return string.equalsString(name)
    }
}
