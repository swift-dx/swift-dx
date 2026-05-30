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

extension Validator {

    static func checkProperties(_ list: [PropertySchema], _ value: JSONValue, _ context: ValidationContext) {
        guard case .object(let object) = value else { return }
        validateEachProperty(list, object, context)
    }

    static func validateEachProperty(_ list: [PropertySchema], _ object: JSONObject, _ context: ValidationContext) {
        for property in list {
            validateProperty(property, object, context)
        }
    }

    static func validateProperty(_ property: PropertySchema, _ object: JSONObject, _ context: ValidationContext) {
        guard case .found(let propertyValue) = object.lookup(property.name) else { return }
        descendProperty(property, propertyValue, context)
    }

    static func descendProperty(_ property: PropertySchema, _ propertyValue: JSONValue, _ context: ValidationContext) {
        context.markProperty(property.name)
        context.pushKeyword("properties")
        context.pushKeyword(property.name)
        context.pushInstanceKey(property.name)
        validateInScope(propertyValue, at: property.schema, context: context)
        context.popInstance()
        context.popKeyword()
        context.popKeyword()
    }

    static func checkPrefixItems(_ indices: [Int], _ value: JSONValue, _ context: ValidationContext) {
        guard case .array(let elements) = value else { return }
        validatePrefixItems(indices, elements, context)
    }

    static func validatePrefixItems(_ indices: [Int], _ elements: [JSONValue], _ context: ValidationContext) {
        context.pushKeyword("prefixItems")
        for index in indices.indices where index < elements.count {
            validatePrefixItem(indices[index], elements[index], index, context)
        }
        context.popKeyword()
    }

    static func validatePrefixItem(_ schema: Int, _ element: JSONValue, _ index: Int, _ context: ValidationContext) {
        context.markItems(upTo: index + 1)
        context.pushKeyword(String(index))
        context.pushInstanceIndex(index)
        validateInScope(element, at: schema, context: context)
        context.popInstance()
        context.popKeyword()
    }

    static func checkItems(_ from: Int, _ schema: Int, _ value: JSONValue, _ context: ValidationContext) {
        guard case .array(let elements) = value else { return }
        validateItemsFrom(from, schema, elements, context)
    }

    static func validateItemsFrom(_ from: Int, _ schema: Int, _ elements: [JSONValue], _ context: ValidationContext) {
        context.pushKeyword("items")
        for index in elements.indices where index >= from {
            validateItem(schema, elements[index], index, context)
        }
        context.popKeyword()
    }

    static func validateItem(_ schema: Int, _ element: JSONValue, _ index: Int, _ context: ValidationContext) {
        context.markItems(upTo: index + 1)
        context.pushInstanceIndex(index)
        validateInScope(element, at: schema, context: context)
        context.popInstance()
    }

    static func checkAdditionalProperties(_ declared: Set<String>, _ patterns: [CompiledPattern], _ schema: Int, _ value: JSONValue, _ context: ValidationContext) {
        guard case .object(let object) = value else { return }
        validateAdditional(declared, patterns, schema, object, context)
    }

    static func validateAdditional(_ declared: Set<String>, _ patterns: [CompiledPattern], _ schema: Int, _ object: JSONObject, _ context: ValidationContext) {
        context.pushKeyword("additionalProperties")
        for member in object.members where isAdditional(member.key, declared, patterns) {
            validateAdditionalMember(schema, member, context)
        }
        context.popKeyword()
    }

    static func isAdditional(_ key: String, _ declared: Set<String>, _ patterns: [CompiledPattern]) -> Bool {
        guard !declared.contains(key) else { return false }
        return !anyPatternMatches(key, patterns)
    }

    static func anyPatternMatches(_ key: String, _ patterns: [CompiledPattern]) -> Bool {
        for pattern in patterns where pattern.matches(key) {
            return true
        }
        return false
    }

    static func validateAdditionalMember(_ schema: Int, _ member: JSONObject.Member, _ context: ValidationContext) {
        context.markProperty(member.key)
        context.pushInstanceKey(member.key)
        validateInScope(member.value, at: schema, context: context)
        context.popInstance()
    }
}
