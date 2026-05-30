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

public enum SchemaValidationResult: Sendable, Equatable {

    case valid
    case invalid([SchemaViolation])
    case instanceNotValidJSON(byteOffset: Int, hint: String)
    case schemaNotRegistered(type: String)

    public var isValid: Bool {
        switch self {
        case .valid: true
        case .invalid: false
        case .instanceNotValidJSON: false
        case .schemaNotRegistered: false
        }
    }

    public var violations: [SchemaViolation] {
        switch self {
        case .valid: []
        case .invalid(let list): list
        case .instanceNotValidJSON: []
        case .schemaNotRegistered: []
        }
    }
}
