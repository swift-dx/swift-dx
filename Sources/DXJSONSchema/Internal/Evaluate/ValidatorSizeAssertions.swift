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

    static func checkMaxLength(_ limit: Int, _ value: JSONValue, _ context: ValidationContext) {
        guard case .string(let string) = value else { return }
        enforceMaxLength(limit, string, context)
    }

    static func enforceMaxLength(_ limit: Int, _ string: JSONString, _ context: ValidationContext) {
        guard string.scalarCount > limit else { return }
        context.record(keyword: "maxLength", message: "string is longer than maxLength \(limit)")
    }

    static func checkMinLength(_ limit: Int, _ value: JSONValue, _ context: ValidationContext) {
        guard case .string(let string) = value else { return }
        enforceMinLength(limit, string, context)
    }

    static func enforceMinLength(_ limit: Int, _ string: JSONString, _ context: ValidationContext) {
        guard string.scalarCount < limit else { return }
        context.record(keyword: "minLength", message: "string is shorter than minLength \(limit)")
    }

    static func checkMaxItems(_ limit: Int, _ value: JSONValue, _ context: ValidationContext) {
        guard case .array(let elements) = value else { return }
        enforceMaxItems(limit, elements.count, context)
    }

    static func enforceMaxItems(_ limit: Int, _ count: Int, _ context: ValidationContext) {
        guard count > limit else { return }
        context.record(keyword: "maxItems", message: "array has more than maxItems \(limit)")
    }

    static func checkMinItems(_ limit: Int, _ value: JSONValue, _ context: ValidationContext) {
        guard case .array(let elements) = value else { return }
        enforceMinItems(limit, elements.count, context)
    }

    static func enforceMinItems(_ limit: Int, _ count: Int, _ context: ValidationContext) {
        guard count < limit else { return }
        context.record(keyword: "minItems", message: "array has fewer than minItems \(limit)")
    }

    static func checkMaxProperties(_ limit: Int, _ value: JSONValue, _ context: ValidationContext) {
        guard case .object(let object) = value else { return }
        enforceMaxProperties(limit, object.count, context)
    }

    static func enforceMaxProperties(_ limit: Int, _ count: Int, _ context: ValidationContext) {
        guard count > limit else { return }
        context.record(keyword: "maxProperties", message: "object has more than maxProperties \(limit)")
    }

    static func checkMinProperties(_ limit: Int, _ value: JSONValue, _ context: ValidationContext) {
        guard case .object(let object) = value else { return }
        enforceMinProperties(limit, object.count, context)
    }

    static func enforceMinProperties(_ limit: Int, _ count: Int, _ context: ValidationContext) {
        guard count < limit else { return }
        context.record(keyword: "minProperties", message: "object has fewer than minProperties \(limit)")
    }

    static func checkUniqueItems(_ value: JSONValue, _ context: ValidationContext) {
        guard case .array(let elements) = value else { return }
        enforceUniqueItems(elements, context)
    }

    static func enforceUniqueItems(_ elements: [JSONValue], _ context: ValidationContext) {
        guard !allUnique(elements) else { return }
        context.record(keyword: "uniqueItems", message: "array contains duplicate items")
    }

    static func allUnique(_ elements: [JSONValue]) -> Bool {
        var seen: Set<JSONValue> = []
        for element in elements where !seen.insert(element).inserted {
            return false
        }
        return true
    }

    static func checkRequired(_ names: [String], _ value: JSONValue, _ context: ValidationContext) {
        guard case .object(let object) = value else { return }
        enforceRequired(names, object, context)
    }

    static func enforceRequired(_ names: [String], _ object: JSONObject, _ context: ValidationContext) {
        for name in names where !object.contains(name) {
            context.record(keyword: "required", message: "missing required property '\(name)'")
        }
    }
}
