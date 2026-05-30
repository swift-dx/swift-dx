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

    static func checkUnevaluatedProperties(_ schema: Int, _ value: JSONValue, _ context: ValidationContext) {
        guard case .object(let object) = value else { return }
        validateUnevaluatedProperties(schema, object, context)
    }

    static func validateUnevaluatedProperties(_ schema: Int, _ object: JSONObject, _ context: ValidationContext) {
        context.pushKeyword("unevaluatedProperties")
        for member in object.members where !context.currentFrame.evaluatedProperties.contains(member.key.value) {
            validateUnevaluatedMember(schema, member, context)
        }
        context.popKeyword()
    }

    static func validateUnevaluatedMember(_ schema: Int, _ member: JSONObject.Member, _ context: ValidationContext) {
        context.markProperty(member.key.value)
        context.pushInstanceKey(member.key.value)
        validateInScope(member.value, at: schema, context: context)
        context.popInstance()
    }

    static func checkUnevaluatedItems(_ schema: Int, _ value: JSONValue, _ context: ValidationContext) {
        guard case .array(let elements) = value else { return }
        validateUnevaluatedItems(schema, elements, context)
    }

    static func validateUnevaluatedItems(_ schema: Int, _ elements: [JSONValue], _ context: ValidationContext) {
        context.pushKeyword("unevaluatedItems")
        for index in elements.indices where isUnevaluatedItem(index, context) {
            validateUnevaluatedItem(schema, elements[index], index, context)
        }
        context.popKeyword()
    }

    static func isUnevaluatedItem(_ index: Int, _ context: ValidationContext) -> Bool {
        guard index >= context.currentFrame.evaluatedItemCount else { return false }
        return !context.currentFrame.containsMatched.contains(index)
    }

    static func validateUnevaluatedItem(_ schema: Int, _ element: JSONValue, _ index: Int, _ context: ValidationContext) {
        context.markItems(upTo: index + 1)
        context.pushInstanceIndex(index)
        validateInScope(element, at: schema, context: context)
        context.popInstance()
    }
}
