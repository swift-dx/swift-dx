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

package enum JSONValue: Sendable {

    case object(JSONObject)
    case array([JSONValue])
    case string(JSONString)
    case number(JSONNumber)
    case bool(Bool)
    case null

    package var kind: JSONValueKind {
        switch self {
        case .object: .object
        case .array: .array
        case .string: .string
        case .number(let number): number.isInteger ? .integer : .number
        case .bool: .boolean
        case .null: .null
        }
    }
}

extension JSONValue: Equatable {

    package static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.object(let a), .object(let b)): a == b
        case (.array(let a), .array(let b)): a == b
        case (.string(let a), .string(let b)): a == b
        case (.number(let a), .number(let b)): a == b
        case (.bool(let a), .bool(let b)): a == b
        case (.null, .null): true
        default: false
        }
    }
}

extension JSONValue: Hashable {

    package func hash(into hasher: inout Hasher) {
        switch self {
        case .object(let object): hashObject(object, into: &hasher)
        case .array(let elements): hasher.combine(elements)
        case .string(let value): hasher.combine(value)
        case .number(let number): hasher.combine(number)
        case .bool(let value): hasher.combine(value)
        case .null: hasher.combine(0)
        }
    }

    private func hashObject(_ object: JSONObject, into hasher: inout Hasher) {
        var combined = 0
        for member in object.members {
            combined ^= memberHash(member)
        }
        hasher.combine(combined)
    }

    private func memberHash(_ member: JSONObject.Member) -> Int {
        var inner = Hasher()
        inner.combine(member.key)
        inner.combine(member.value)
        return inner.finalize()
    }
}
