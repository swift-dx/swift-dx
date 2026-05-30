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

    static func checkContains(_ schema: Int, _ minimum: Int, _ maximum: ContainsMaximum, _ value: JSONValue, _ context: ValidationContext) {
        guard case .array(let elements) = value else { return }
        enforceContains(schema, minimum, maximum, elements, context)
    }

    static func enforceContains(_ schema: Int, _ minimum: Int, _ maximum: ContainsMaximum, _ elements: [JSONValue], _ context: ValidationContext) {
        let count = matchingCount(schema, elements, context)
        recordContains(count, minimum, maximum, context)
    }

    static func matchingCount(_ schema: Int, _ elements: [JSONValue], _ context: ValidationContext) -> Int {
        var count = 0
        for index in elements.indices where branchValidates(elements[index], schema, context) {
            count += markMatch(index, context)
        }
        return count
    }

    static func markMatch(_ index: Int, _ context: ValidationContext) -> Int {
        context.markContains(index)
        return 1
    }

    static func recordContains(_ count: Int, _ minimum: Int, _ maximum: ContainsMaximum, _ context: ValidationContext) {
        enforceContainsMinimum(count, minimum, context)
        enforceContainsMaximum(count, maximum, context)
    }

    static func enforceContainsMinimum(_ count: Int, _ minimum: Int, _ context: ValidationContext) {
        guard count < minimum else { return }
        context.record(keyword: "contains", message: "fewer than \(minimum) items match the contains schema")
    }

    static func enforceContainsMaximum(_ count: Int, _ maximum: ContainsMaximum, _ context: ValidationContext) {
        guard case .bounded(let limit) = maximum, count > limit else { return }
        context.record(keyword: "maxContains", message: "more than \(limit) items match the contains schema")
    }
}
