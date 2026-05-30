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

enum CompiledKeyword: Sendable {

    case reference(slot: Int)
    case dynamicReference(name: String, fallbackSlot: Int)
    case type(TypeConstraint)
    case constValue(JSONValue)
    case enumValues([JSONValue])
    case multipleOf(JSONNumber)
    case maximum(JSONNumber)
    case exclusiveMaximum(JSONNumber)
    case minimum(JSONNumber)
    case exclusiveMinimum(JSONNumber)
    case maxLength(Int)
    case minLength(Int)
    case pattern(CompiledPattern)
    case format(FormatKind)
    case maxItems(Int)
    case minItems(Int)
    case uniqueItems
    case maxProperties(Int)
    case minProperties(Int)
    case required([String])
    case properties([PropertySchema])
    case patternProperties([PatternSchema])
    case propertyNames(Int)
    case dependentRequired([DependentRequirement])
    case dependentSchemas([DependentSchema])
    case prefixItems([Int])
    case items(from: Int, schema: Int)
    case contains(schema: Int, minimum: Int, maximum: ContainsMaximum)
    case unevaluatedProperties(Int)
    case unevaluatedItems(Int)
    case additionalProperties(declared: Set<JSONString>, patterns: [CompiledPattern], schema: Int)
    case allOf([Int])
    case anyOf([Int])
    case oneOf([Int])
    case not(Int)
    case ifThenElse(condition: Int, success: SubschemaSlot, failure: SubschemaSlot)
}
