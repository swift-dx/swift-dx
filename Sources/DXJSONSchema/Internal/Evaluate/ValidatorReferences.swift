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

    static func checkReference(_ slot: Int, _ value: JSONValue, _ context: ValidationContext) {
        context.pushKeyword("$ref")
        evaluateInPlace(value, at: context.document.refTarget(at: slot), context: context)
        context.popKeyword()
    }

    static func checkDynamicReference(_ name: String, _ slot: Int, _ value: JSONValue, _ context: ValidationContext) {
        let fallback = context.document.refTarget(at: slot)
        let target = resolveDynamicTarget(name, fallback, context)
        context.pushKeyword("$dynamicRef")
        evaluateInPlace(value, at: target, context: context)
        context.popKeyword()
    }

    static func resolveDynamicTarget(_ name: String, _ fallback: Int, _ context: ValidationContext) -> Int {
        guard staticTargetIsDynamicAnchor(name, fallback, context) else { return fallback }
        return context.dynamicTarget(name, fallback: fallback)
    }

    static func staticTargetIsDynamicAnchor(_ name: String, _ fallback: Int, _ context: ValidationContext) -> Bool {
        guard case .found(let anchorName) = context.document.dynamicAnchorName(at: fallback) else { return false }
        return anchorName == name
    }
}
