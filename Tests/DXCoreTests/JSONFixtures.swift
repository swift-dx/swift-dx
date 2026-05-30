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

@testable import DXCore

enum JSONFixtures {

    static func signedInteger(_ value: Int64) -> JSONValue {
        .number(JSONNumber(form: .signedInteger(value)))
    }

    static func unsignedInteger(_ value: UInt64) -> JSONValue {
        .number(JSONNumber(form: .unsignedInteger(value)))
    }

    static func decimal(_ value: Double) -> JSONValue {
        .number(JSONNumber(form: .decimal(value)))
    }

    static func object(_ pairs: [(String, JSONValue)]) -> JSONValue {
        .object(JSONObject(members: pairs.map { JSONObject.Member(key: JSONString($0.0), value: $0.1) }))
    }

    static func array(_ elements: [JSONValue]) -> JSONValue {
        .array(elements)
    }

    static func parseObject(_ text: String) -> JSONObject {
        switch parsedValue(text) {
        case .object(let object): return object
        default: return JSONObject(members: [])
        }
    }

    static func parsedValue(_ text: String) -> JSONValue {
        do {
            return try JSONParser.parse(text)
        } catch {
            return .null
        }
    }

    static func capturedError(_ text: String) -> Lookup<JSONParseError> {
        do {
            _ = try JSONParser.parse(text)
            return .notFound
        } catch {
            return .found(error)
        }
    }

    static func capturedError(_ bytes: [UInt8], limits: JSONParseLimits) -> Lookup<JSONParseError> {
        do {
            _ = try JSONParser.parse(bytes, limits: limits)
            return .notFound
        } catch {
            return .found(error)
        }
    }
}
