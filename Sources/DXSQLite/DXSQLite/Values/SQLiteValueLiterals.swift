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

// Literal conformances let a parameter list read as `["Ada", 42, 2.5, true]`
// instead of the fully spelled-out cases. SQL NULL is intentionally NOT a nil
// literal: callers write `.null` so the absence is explicit on the page.

extension SQLiteValue: ExpressibleByStringLiteral {

    public init(stringLiteral value: String) {
        self = .text(value)
    }
}

extension SQLiteValue: ExpressibleByIntegerLiteral {

    public init(integerLiteral value: Int64) {
        self = .integer(value)
    }
}

extension SQLiteValue: ExpressibleByFloatLiteral {

    public init(floatLiteral value: Double) {
        self = .real(value)
    }
}

extension SQLiteValue: ExpressibleByBooleanLiteral {

    public init(booleanLiteral value: Bool) {
        self = .integer(value ? 1 : 0)
    }
}
