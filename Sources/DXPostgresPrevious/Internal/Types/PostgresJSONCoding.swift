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

import Foundation

// Bridges `json`/`jsonb` columns to Foundation's Codable via JSON. A binary
// `jsonb` value carries a leading 0x01 version byte before the JSON text, which
// is stripped here; `json` and the text format are already raw JSON. Decoding and
// encoding failures are narrowed to the library's typed JSON errors.
enum PostgresJSONCoding {

    static func payloadBytes(_ value: PostgresDecodingValue) -> [UInt8] {
        guard value.format == .binary, value.dataTypeObjectID == 3802, value.bytes.first == 1 else {
            return value.bytes
        }
        return Array(value.bytes.dropFirst())
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from value: PostgresDecodingValue) throws(PostgresError) -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: Data(payloadBytes(value)))
        } catch {
            throw PostgresError.jsonDecodingFailed(typeName: "\(Value.self)", reason: String(describing: error))
        }
    }

    static func encode<Value: Encodable>(_ value: Value) throws(PostgresError) -> [UInt8] {
        do {
            return Array(try JSONEncoder().encode(value))
        } catch {
            throw PostgresError.jsonEncodingFailed(typeName: "\(Value.self)", reason: String(describing: error))
        }
    }
}
