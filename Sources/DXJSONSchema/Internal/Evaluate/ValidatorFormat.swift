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

    static func checkFormat(_ kind: FormatKind, _ value: JSONValue, _ context: ValidationContext) {
        guard case .string(let string) = value else { return }
        enforceFormat(kind, string, context)
    }

    static func enforceFormat(_ kind: FormatKind, _ string: String, _ context: ValidationContext) {
        guard !FormatValidator.check(kind, string) else { return }
        context.record(keyword: "format", message: "string does not satisfy the required format")
    }
}
