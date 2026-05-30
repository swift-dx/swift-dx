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

    static func checkOneOf(_ indices: [Int], _ value: JSONValue, _ context: ValidationContext) {
        guard context.tracksEvaluation else { return checkOneOfFast(indices, value, context) }
        checkOneOfTracked(indices, value, context)
    }

    static func checkOneOfFast(_ indices: [Int], _ value: JSONValue, _ context: ValidationContext) {
        guard countValidBranches(indices, value, context) != 1 else { return }
        context.record(keyword: "oneOf", message: "value must match exactly one of the required schemas")
    }

    static func countValidBranches(_ indices: [Int], _ value: JSONValue, _ context: ValidationContext) -> Int {
        var count = 0
        for schema in indices where branchValidates(value, schema, context) {
            count += 1
        }
        return count
    }

    static func checkOneOfTracked(_ indices: [Int], _ value: JSONValue, _ context: ValidationContext) {
        var winners: [EvaluationFrame] = []
        for schema in indices {
            collectWinner(value, schema, &winners, context)
        }
        finishOneOf(winners, context)
    }

    static func collectWinner(_ value: JSONValue, _ schema: Int, _ winners: inout [EvaluationFrame], _ context: ValidationContext) {
        let probe = probeEvaluate(value, schema, context)
        guard probe.valid else { return }
        winners.append(probe.frame)
    }

    static func finishOneOf(_ winners: [EvaluationFrame], _ context: ValidationContext) {
        guard winners.count == 1 else { return recordOneOf(context) }
        context.absorb(winners[0])
    }

    static func recordOneOf(_ context: ValidationContext) {
        context.record(keyword: "oneOf", message: "value must match exactly one of the required schemas")
    }
}
