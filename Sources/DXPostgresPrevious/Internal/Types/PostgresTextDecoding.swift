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
import Foundation

// Shared text-format decoders backing the PostgresDecodable conformances. Each
// turns a column's UTF-8 text rendering into a Swift value, throwing a typed
// decoding error naming the target type and the offending text when the bytes do
// not parse.
enum PostgresTextDecoding {

    static func uuid(_ value: PostgresDecodingValue) throws(PostgresError) -> UUID {
        guard let uuid = UUID(uuidString: value.text) else {
            throw PostgresError.typeDecodingFailed(type: "UUID", reason: "'\(value.text)' is not a valid UUID")
        }
        return uuid
    }

    // A jsonb value in binary format is prefixed with a single 0x01 version byte
    // ahead of the JSON text; every other string-like value is its raw UTF-8.
    static func string(_ value: PostgresDecodingValue) -> String {
        guard value.format == .binary, value.dataTypeObjectID == 3802, value.bytes.first == 1 else {
            return value.text
        }
        return String(decoding: value.bytes.dropFirst(), as: UTF8.self)
    }

    static func decimal(_ value: PostgresDecodingValue) throws(PostgresError) -> Decimal {
        let text = value.dataTypeObjectID == 790 ? sanitizedMoney(value.text) : value.text
        guard let decimal = Decimal(string: text) else {
            throw PostgresError.typeDecodingFailed(type: "Decimal", reason: "'\(value.text)' is not a valid numeric")
        }
        return decimal
    }

    // money renders with a currency symbol and locale grouping (for example
    // "$1,234.56" or "($5.00)" for negatives). This keeps the sign, digits, and
    // decimal point under the common period-decimal locale; for other locales,
    // cast the column to numeric in SQL.
    private static func sanitizedMoney(_ text: String) -> String {
        let negative = text.hasPrefix("-") || text.contains("(")
        let digits = String(text.filter { $0.isNumber || $0 == "." })
        return negative ? "-" + digits : digits
    }

    static func lossless<Value: LosslessStringConvertible>(_ value: PostgresDecodingValue, as type: Value.Type) throws(PostgresError) -> Value {
        guard let parsed = Value(value.text) else {
            throw PostgresError.typeDecodingFailed(type: "\(Value.self)", reason: "'\(value.text)' is not a valid \(Value.self)")
        }
        return parsed
    }

    static func boolean(_ value: PostgresDecodingValue) throws(PostgresError) -> Bool {
        switch value.text {
        case "t", "true", "1", "y", "yes", "on": return true
        case "f", "false", "0", "n", "no", "off": return false
        default: throw PostgresError.typeDecodingFailed(type: "Bool", reason: "unexpected boolean text '\(value.text)'")
        }
    }

    static func bytea(_ value: PostgresDecodingValue) throws(PostgresError) -> [UInt8] {
        let text = value.text
        guard text.hasPrefix("\\x") else {
            throw PostgresError.typeDecodingFailed(type: "[UInt8]", reason: "expected hex-format bytea beginning with \\x")
        }
        do {
            return try Hex.decode(String(text.dropFirst(2)))
        } catch {
            throw PostgresError.typeDecodingFailed(type: "[UInt8]", reason: "bytea value contains invalid hex")
        }
    }
}
