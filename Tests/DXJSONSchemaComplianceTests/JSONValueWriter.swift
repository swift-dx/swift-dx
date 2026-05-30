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

enum JSONValueWriter {

    static func write(_ value: JSONValue) -> String {
        switch value {
        case .object(let object): writeObject(object)
        case .array(let elements): writeArray(elements)
        case .string(let text): writeString(text)
        case .number(let number): number.source
        case .bool(let flag): writeBool(flag)
        case .null: "null"
        }
    }

    static func writeBool(_ flag: Bool) -> String {
        flag ? "true" : "false"
    }

    static func writeObject(_ object: JSONObject) -> String {
        let members = object.members.map { writeMember($0) }
        return "{" + members.joined(separator: ",") + "}"
    }

    static func writeMember(_ member: JSONObject.Member) -> String {
        writeString(member.key) + ":" + write(member.value)
    }

    static func writeArray(_ elements: [JSONValue]) -> String {
        let parts = elements.map { write($0) }
        return "[" + parts.joined(separator: ",") + "]"
    }

    static func writeString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            out += escapeScalar(scalar)
        }
        return out + "\""
    }

    static func escapeScalar(_ scalar: Unicode.Scalar) -> String {
        switch scalar {
        case "\"": "\\\""
        case "\\": "\\\\"
        case "\n": "\\n"
        case "\r": "\\r"
        case "\t": "\\t"
        default: passThroughOrEscape(scalar)
        }
    }

    static func passThroughOrEscape(_ scalar: Unicode.Scalar) -> String {
        guard scalar.value < 0x20 else { return String(scalar) }
        return controlEscape(scalar.value)
    }

    static func controlEscape(_ value: UInt32) -> String {
        let hex = String(value, radix: 16)
        let padded = String(repeating: "0", count: 4 - hex.count) + hex
        return "\\u" + padded
    }
}
