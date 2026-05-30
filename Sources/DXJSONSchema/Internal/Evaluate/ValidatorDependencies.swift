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

    static func checkDependentRequired(_ list: [DependentRequirement], _ value: JSONValue, _ context: ValidationContext) {
        guard case .object(let object) = value else { return }
        enforceDependentRequired(list, object, context)
    }

    static func enforceDependentRequired(_ list: [DependentRequirement], _ object: JSONObject, _ context: ValidationContext) {
        for requirement in list where object.contains(requirement.trigger) {
            enforceRequirement(requirement, object, context)
        }
    }

    static func enforceRequirement(_ requirement: DependentRequirement, _ object: JSONObject, _ context: ValidationContext) {
        for name in requirement.required where !object.contains(name) {
            context.record(keyword: "dependentRequired", message: "property '\(requirement.trigger)' requires property '\(name)'")
        }
    }

    static func checkDependentSchemas(_ list: [DependentSchema], _ value: JSONValue, _ context: ValidationContext) {
        guard case .object(let object) = value else { return }
        enforceDependentSchemas(list, object, value, context)
    }

    static func enforceDependentSchemas(_ list: [DependentSchema], _ object: JSONObject, _ value: JSONValue, _ context: ValidationContext) {
        for dependent in list where object.contains(dependent.trigger) {
            descendDependentSchema(dependent, value, context)
        }
    }

    static func descendDependentSchema(_ dependent: DependentSchema, _ value: JSONValue, _ context: ValidationContext) {
        context.pushKeyword("dependentSchemas")
        context.pushKeyword(dependent.trigger)
        evaluateInPlace(value, at: dependent.schema, context: context)
        context.popKeyword()
        context.popKeyword()
    }
}
