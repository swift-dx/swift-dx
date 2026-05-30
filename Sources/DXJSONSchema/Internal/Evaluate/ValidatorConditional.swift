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

    static func checkIfThenElse(_ condition: Int, _ success: SubschemaSlot, _ failure: SubschemaSlot, _ value: JSONValue, _ context: ValidationContext) {
        guard context.tracksEvaluation else { return checkIfThenElseFast(condition, success, failure, value, context) }
        checkIfThenElseTracked(condition, success, failure, value, context)
    }

    static func checkIfThenElseFast(_ condition: Int, _ success: SubschemaSlot, _ failure: SubschemaSlot, _ value: JSONValue, _ context: ValidationContext) {
        if branchValidates(value, condition, context) {
            applySlot(success, keyword: "then", value, context)
        } else {
            applySlot(failure, keyword: "else", value, context)
        }
    }

    static func checkIfThenElseTracked(_ condition: Int, _ success: SubschemaSlot, _ failure: SubschemaSlot, _ value: JSONValue, _ context: ValidationContext) {
        let probe = probeEvaluate(value, condition, context)
        applyConditional(probe, success, failure, value, context)
    }

    static func applyConditional(_ probe: ProbeResult, _ success: SubschemaSlot, _ failure: SubschemaSlot, _ value: JSONValue, _ context: ValidationContext) {
        guard probe.valid else { return applySlot(failure, keyword: "else", value, context) }
        context.absorb(probe.frame)
        applySlot(success, keyword: "then", value, context)
    }

    static func applySlot(_ slot: SubschemaSlot, keyword: String, _ value: JSONValue, _ context: ValidationContext) {
        guard case .present(let schema) = slot else { return }
        descendSlot(schema, keyword, value, context)
    }

    static func descendSlot(_ schema: Int, _ keyword: String, _ value: JSONValue, _ context: ValidationContext) {
        context.pushKeyword(keyword)
        evaluateInPlace(value, at: schema, context: context)
        context.popKeyword()
    }
}
