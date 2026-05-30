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

enum Validator {

    static func validate(_ value: JSONValue, with document: CompiledDocument) -> SchemaValidationResult {
        let fast = ValidationContext(document: document, tracksLocations: false)
        validateInScope(value, at: document.root, context: fast)
        guard !fast.violations.isEmpty else { return .valid }
        return collectWithLocations(value, document)
    }

    static func collectWithLocations(_ value: JSONValue, _ document: CompiledDocument) -> SchemaValidationResult {
        let context = ValidationContext(document: document, tracksLocations: true)
        validateInScope(value, at: document.root, context: context)
        return .invalid(context.violations)
    }

    static func validateInScope(_ value: JSONValue, at index: Int, context: ValidationContext) {
        guard context.tracksEvaluation else { return validateNode(value, at: index, context: context) }
        enterScope(value, at: index, context: context)
    }

    static func enterScope(_ value: JSONValue, at index: Int, context: ValidationContext) {
        context.pushFrame()
        validateNode(value, at: index, context: context)
        context.popFrame()
    }

    static func evaluateInPlace(_ value: JSONValue, at index: Int, context: ValidationContext) {
        guard context.tracksEvaluation else { return validateNode(value, at: index, context: context) }
        context.pushFrame()
        validateNode(value, at: index, context: context)
        mergeInPlaceFrame(context)
    }

    static func mergeInPlaceFrame(_ context: ValidationContext) {
        let child = context.currentFrame
        context.popFrame()
        context.absorb(child)
    }

    static func probeEvaluate(_ value: JSONValue, _ index: Int, _ context: ValidationContext) -> ProbeResult {
        let probe = ValidationContext(document: context.document, tracksLocations: false)
        probe.dynamicScope = context.dynamicScope
        probe.pushFrame()
        validateNode(value, at: index, context: probe)
        return ProbeResult(valid: probe.violations.isEmpty, frame: probe.currentFrame)
    }

    static func validateNode(_ value: JSONValue, at index: Int, context: ValidationContext) {
        guard context.descend() else { return context.recordRecursionLimit() }
        let pushed = enterDynamicScope(index, context)
        dispatchNode(value, at: index, context: context)
        leaveDynamicScope(pushed, context)
        context.ascend()
    }

    static func enterDynamicScope(_ index: Int, _ context: ValidationContext) -> Bool {
        guard context.tracksDynamicScope else { return false }
        return context.pushResource(at: index)
    }

    static func leaveDynamicScope(_ pushed: Bool, _ context: ValidationContext) {
        guard pushed else { return }
        context.popResource()
    }

    static func dispatchNode(_ value: JSONValue, at index: Int, context: ValidationContext) {
        switch context.document.node(at: index) {
        case .always: break
        case .never: context.recordNever()
        case .keywords(let keywords): applyKeywords(keywords, to: value, context: context)
        }
    }

    static func applyKeywords(_ keywords: [CompiledKeyword], to value: JSONValue, context: ValidationContext) {
        for keyword in keywords {
            applyKeyword(keyword, to: value, context: context)
        }
    }

    static func branchValidates(_ value: JSONValue, _ index: Int, _ context: ValidationContext) -> Bool {
        let probe = ValidationContext(document: context.document, tracksLocations: false)
        inheritScope(probe, context)
        prepareProbe(probe)
        validateNode(value, at: index, context: probe)
        return probe.violations.isEmpty
    }

    static func prepareProbe(_ probe: ValidationContext) {
        guard probe.tracksEvaluation else { return }
        probe.pushFrame()
    }

    static func inheritScope(_ probe: ValidationContext, _ context: ValidationContext) {
        probe.dynamicScope = context.dynamicScope
    }

    static func applyKeyword(_ keyword: CompiledKeyword, to value: JSONValue, context: ValidationContext) {
        switch keyword {
        case .reference(let slot): checkReference(slot, value, context)
        case .dynamicReference(let name, let slot): checkDynamicReference(name, slot, value, context)
        case .type(let constraint): checkType(constraint, value, context)
        case .constValue(let expected): checkConst(expected, value, context)
        case .enumValues(let allowed): checkEnum(allowed, value, context)
        case .multipleOf(let factor): checkMultipleOf(factor, value, context)
        case .maximum(let limit): checkMaximum(limit, value, context)
        case .exclusiveMaximum(let limit): checkExclusiveMaximum(limit, value, context)
        case .minimum(let limit): checkMinimum(limit, value, context)
        case .exclusiveMinimum(let limit): checkExclusiveMinimum(limit, value, context)
        case .maxLength(let limit): checkMaxLength(limit, value, context)
        case .minLength(let limit): checkMinLength(limit, value, context)
        case .pattern(let compiled): checkPattern(compiled, value, context)
        case .format(let kind): checkFormat(kind, value, context)
        case .maxItems(let limit): checkMaxItems(limit, value, context)
        case .minItems(let limit): checkMinItems(limit, value, context)
        case .uniqueItems: checkUniqueItems(value, context)
        case .maxProperties(let limit): checkMaxProperties(limit, value, context)
        case .minProperties(let limit): checkMinProperties(limit, value, context)
        case .required(let names): checkRequired(names, value, context)
        case .properties(let list): checkProperties(list, value, context)
        case .patternProperties(let list): checkPatternProperties(list, value, context)
        case .propertyNames(let schema): checkPropertyNames(schema, value, context)
        case .dependentRequired(let list): checkDependentRequired(list, value, context)
        case .dependentSchemas(let list): checkDependentSchemas(list, value, context)
        case .prefixItems(let indices): checkPrefixItems(indices, value, context)
        case .items(let from, let schema): checkItems(from, schema, value, context)
        case .contains(let schema, let minimum, let maximum): checkContains(schema, minimum, maximum, value, context)
        case .unevaluatedProperties(let schema): checkUnevaluatedProperties(schema, value, context)
        case .unevaluatedItems(let schema): checkUnevaluatedItems(schema, value, context)
        case .additionalProperties(let declared, let patterns, let schema): checkAdditionalProperties(declared, patterns, schema, value, context)
        case .allOf(let indices): checkAllOf(indices, value, context)
        case .anyOf(let indices): checkAnyOf(indices, value, context)
        case .oneOf(let indices): checkOneOf(indices, value, context)
        case .not(let schema): checkNot(schema, value, context)
        case .ifThenElse(let condition, let success, let failure): checkIfThenElse(condition, success, failure, value, context)
        }
    }
}
