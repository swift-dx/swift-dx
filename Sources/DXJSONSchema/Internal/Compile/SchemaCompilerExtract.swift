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

extension SchemaCompiler {

    func requireNumber(_ value: JSONValue, keyword: String, at location: String) throws(JSONSchemaError) -> JSONNumber {
        guard case .number(let number) = value else {
            throw .keywordValueMalformed(keyword: keyword, keywordLocation: location, expected: "a number")
        }
        return number
    }

    func requireNonNegativeInt(_ value: JSONValue, keyword: String, at location: String) throws(JSONSchemaError) -> Int {
        guard case .number(let number) = value, case .found(let count) = nonNegativeIntValue(number) else {
            throw .keywordValueMalformed(keyword: keyword, keywordLocation: location, expected: "a non-negative integer")
        }
        return count
    }

    func nonNegativeIntValue(_ number: JSONNumber) -> Lookup<Int> {
        guard number.isInteger, number.doubleValue >= 0 else { return .notFound }
        return boundedInt(number.doubleValue)
    }

    func boundedInt(_ value: Double) -> Lookup<Int> {
        guard let exact = Int(exactly: value) else { return .found(Int.max) }
        return .found(exact)
    }

    func requireArray(_ value: JSONValue, keyword: String, at location: String) throws(JSONSchemaError) -> [JSONValue] {
        guard case .array(let elements) = value else {
            throw .keywordValueMalformed(keyword: keyword, keywordLocation: location, expected: "an array")
        }
        return elements
    }

    func requireStringArray(_ value: JSONValue, keyword: String, at location: String) throws(JSONSchemaError) -> [String] {
        guard case .array(let elements) = value else {
            throw .keywordValueMalformed(keyword: keyword, keywordLocation: location, expected: "an array of strings")
        }
        return try mapToStrings(elements, keyword: keyword, at: location)
    }

    func mapToStrings(_ elements: [JSONValue], keyword: String, at location: String) throws(JSONSchemaError) -> [String] {
        var names: [String] = []
        for element in elements {
            names.append(try requireStringElement(element, keyword: keyword, at: location))
        }
        return names
    }

    func requireStringElement(_ value: JSONValue, keyword: String, at location: String) throws(JSONSchemaError) -> String {
        guard case .string(let string) = value else {
            throw .keywordValueMalformed(keyword: keyword, keywordLocation: location, expected: "an array of strings")
        }
        return string
    }

    func buildTypeConstraint(_ value: JSONValue, at location: String) throws(JSONSchemaError) -> TypeConstraint {
        switch value {
        case .string(let name): return TypeConstraint(allowed: [try typeKind(name, at: location)])
        case .array(let names): return TypeConstraint(allowed: try typeKindSet(names, at: location))
        default: throw .keywordValueMalformed(keyword: "type", keywordLocation: location, expected: "a string or array of strings")
        }
    }

    func typeKindSet(_ names: [JSONValue], at location: String) throws(JSONSchemaError) -> Set<JSONValueKind> {
        var kinds: Set<JSONValueKind> = []
        for name in names {
            kinds.insert(try typeKindFromValue(name, at: location))
        }
        return kinds
    }

    func typeKindFromValue(_ value: JSONValue, at location: String) throws(JSONSchemaError) -> JSONValueKind {
        guard case .string(let name) = value else {
            throw .keywordValueMalformed(keyword: "type", keywordLocation: location, expected: "a string or array of strings")
        }
        return try typeKind(name, at: location)
    }

    func typeKind(_ name: String, at location: String) throws(JSONSchemaError) -> JSONValueKind {
        switch name {
        case "object": return .object
        case "array": return .array
        case "string": return .string
        case "integer": return .integer
        case "number": return .number
        case "boolean": return .boolean
        case "null": return .null
        default: throw .keywordValueMalformed(keyword: "type", keywordLocation: location, expected: "a known JSON type name")
        }
    }
}
