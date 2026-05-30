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

    static func checkType(_ constraint: TypeConstraint, _ value: JSONValue, _ context: ValidationContext) {
        guard !constraint.permits(value.kind) else { return }
        context.record(keyword: "type", message: "value of type \(value.kind.rawValue) is not an allowed type")
    }

    static func checkConst(_ expected: JSONValue, _ value: JSONValue, _ context: ValidationContext) {
        guard expected != value else { return }
        context.record(keyword: "const", message: "value does not equal the required constant")
    }

    static func checkEnum(_ allowed: [JSONValue], _ value: JSONValue, _ context: ValidationContext) {
        guard !allowed.contains(value) else { return }
        context.record(keyword: "enum", message: "value is not one of the permitted enumerated values")
    }

    static func checkMultipleOf(_ factor: JSONNumber, _ value: JSONValue, _ context: ValidationContext) {
        guard case .number(let number) = value else { return }
        enforceMultipleOf(factor, number, context)
    }

    static func enforceMultipleOf(_ factor: JSONNumber, _ number: JSONNumber, _ context: ValidationContext) {
        guard !NumberComparison.isMultiple(number, of: factor) else { return }
        context.record(keyword: "multipleOf", message: "value is not a multiple of \(factor.source)")
    }

    static func checkMaximum(_ limit: JSONNumber, _ value: JSONValue, _ context: ValidationContext) {
        guard case .number(let number) = value else { return }
        enforceMaximum(limit, number, context)
    }

    static func enforceMaximum(_ limit: JSONNumber, _ number: JSONNumber, _ context: ValidationContext) {
        guard NumberComparison.order(number, limit) == .descending else { return }
        context.record(keyword: "maximum", message: "value is greater than the maximum \(limit.source)")
    }

    static func checkExclusiveMaximum(_ limit: JSONNumber, _ value: JSONValue, _ context: ValidationContext) {
        guard case .number(let number) = value else { return }
        enforceExclusiveMaximum(limit, number, context)
    }

    static func enforceExclusiveMaximum(_ limit: JSONNumber, _ number: JSONNumber, _ context: ValidationContext) {
        guard NumberComparison.order(number, limit) != .ascending else { return }
        context.record(keyword: "exclusiveMaximum", message: "value is not less than the exclusive maximum \(limit.source)")
    }

    static func checkMinimum(_ limit: JSONNumber, _ value: JSONValue, _ context: ValidationContext) {
        guard case .number(let number) = value else { return }
        enforceMinimum(limit, number, context)
    }

    static func enforceMinimum(_ limit: JSONNumber, _ number: JSONNumber, _ context: ValidationContext) {
        guard NumberComparison.order(number, limit) == .ascending else { return }
        context.record(keyword: "minimum", message: "value is less than the minimum \(limit.source)")
    }

    static func checkExclusiveMinimum(_ limit: JSONNumber, _ value: JSONValue, _ context: ValidationContext) {
        guard case .number(let number) = value else { return }
        enforceExclusiveMinimum(limit, number, context)
    }

    static func enforceExclusiveMinimum(_ limit: JSONNumber, _ number: JSONNumber, _ context: ValidationContext) {
        guard NumberComparison.order(number, limit) != .descending else { return }
        context.record(keyword: "exclusiveMinimum", message: "value is not greater than the exclusive minimum \(limit.source)")
    }
}
