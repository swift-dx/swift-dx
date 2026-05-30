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

    static func checkAllOf(_ indices: [Int], _ value: JSONValue, _ context: ValidationContext) {
        context.pushKeyword("allOf")
        for offset in indices.indices {
            validateBranchInPlace(indices[offset], offset, value, context)
        }
        context.popKeyword()
    }

    static func validateBranchInPlace(_ schema: Int, _ offset: Int, _ value: JSONValue, _ context: ValidationContext) {
        context.pushKeyword(String(offset))
        evaluateInPlace(value, at: schema, context: context)
        context.popKeyword()
    }

    static func checkAnyOf(_ indices: [Int], _ value: JSONValue, _ context: ValidationContext) {
        guard context.tracksEvaluation else { return checkAnyOfFast(indices, value, context) }
        checkAnyOfTracked(indices, value, context)
    }

    static func checkAnyOfFast(_ indices: [Int], _ value: JSONValue, _ context: ValidationContext) {
        guard !anyBranchValid(indices, value, context) else { return }
        context.record(keyword: "anyOf", message: "value does not match any of the required schemas")
    }

    static func anyBranchValid(_ indices: [Int], _ value: JSONValue, _ context: ValidationContext) -> Bool {
        for schema in indices where branchValidates(value, schema, context) {
            return true
        }
        return false
    }

    static func checkAnyOfTracked(_ indices: [Int], _ value: JSONValue, _ context: ValidationContext) {
        var matched = false
        for schema in indices where absorbIfValid(value, schema, context) {
            matched = true
        }
        recordAnyOf(matched, context)
    }

    static func absorbIfValid(_ value: JSONValue, _ schema: Int, _ context: ValidationContext) -> Bool {
        let probe = probeEvaluate(value, schema, context)
        guard probe.valid else { return false }
        context.absorb(probe.frame)
        return true
    }

    static func recordAnyOf(_ matched: Bool, _ context: ValidationContext) {
        guard !matched else { return }
        context.record(keyword: "anyOf", message: "value does not match any of the required schemas")
    }

    static func checkNot(_ schema: Int, _ value: JSONValue, _ context: ValidationContext) {
        guard branchValidates(value, schema, context) else { return }
        context.record(keyword: "not", message: "value must not match the schema")
    }
}
