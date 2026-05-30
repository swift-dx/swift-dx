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

    static func checkPattern(_ pattern: CompiledPattern, _ value: JSONValue, _ context: ValidationContext) {
        guard case .string(let string) = value else { return }
        enforcePattern(pattern, string, context)
    }

    static func enforcePattern(_ pattern: CompiledPattern, _ string: JSONString, _ context: ValidationContext) {
        guard !pattern.matches(string.value) else { return }
        context.record(keyword: "pattern", message: "string does not match the required pattern \(pattern.source)")
    }

    static func checkPatternProperties(_ list: [PatternSchema], _ value: JSONValue, _ context: ValidationContext) {
        guard case .object(let object) = value else { return }
        validatePatternProperties(list, object, context)
    }

    static func validatePatternProperties(_ list: [PatternSchema], _ object: JSONObject, _ context: ValidationContext) {
        for entry in list {
            validatePatternEntry(entry, object, context)
        }
    }

    static func validatePatternEntry(_ entry: PatternSchema, _ object: JSONObject, _ context: ValidationContext) {
        context.pushKeyword("patternProperties")
        context.pushKeyword(entry.pattern.source)
        validateMatchingMembers(entry, object, context)
        context.popKeyword()
        context.popKeyword()
    }

    static func validateMatchingMembers(_ entry: PatternSchema, _ object: JSONObject, _ context: ValidationContext) {
        for member in object.members where entry.pattern.matches(member.key.value) {
            validateMatchingMember(entry.schema, member, context)
        }
    }

    static func validateMatchingMember(_ schema: Int, _ member: JSONObject.Member, _ context: ValidationContext) {
        context.markProperty(member.key.value)
        context.pushInstanceKey(member.key.value)
        validateInScope(member.value, at: schema, context: context)
        context.popInstance()
    }

    static func checkPropertyNames(_ schema: Int, _ value: JSONValue, _ context: ValidationContext) {
        guard case .object(let object) = value else { return }
        validatePropertyNames(schema, object, context)
    }

    static func validatePropertyNames(_ schema: Int, _ object: JSONObject, _ context: ValidationContext) {
        for member in object.members where !branchValidates(.string(member.key), schema, context) {
            recordPropertyName(member.key.value, context)
        }
    }

    static func recordPropertyName(_ name: String, _ context: ValidationContext) {
        context.record(keyword: "propertyNames", message: "property name '\(name)' does not satisfy the propertyNames schema")
    }
}
