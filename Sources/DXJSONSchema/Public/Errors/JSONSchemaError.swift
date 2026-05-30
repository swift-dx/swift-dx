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

public enum JSONSchemaError: Error, Sendable, Equatable {

    case schemaNotValidJSON(byteOffset: Int, hint: String)
    case schemaNotObjectOrBoolean(keywordLocation: String)
    case keywordValueMalformed(keyword: String, keywordLocation: String, expected: String)
    case unsupportedKeyword(keyword: String, keywordLocation: String)
    case patternNotValid(keywordLocation: String, pattern: String)
    case unresolvedReference(reference: String, keywordLocation: String)
    case invalidSchemaType
    case invalidSchemaStructure(type: String)
    case unknownRequiredVocabulary(uri: String)
}

extension JSONSchemaError: CustomStringConvertible {

    public var description: String {
        switch self {
        case .schemaNotValidJSON(let offset, let hint): "schema is not valid JSON at byte \(offset): \(hint)"
        case .schemaNotObjectOrBoolean(let location): "schema at '\(location)' must be a JSON object or boolean"
        case .keywordValueMalformed(let keyword, let location, let expected): "keyword '\(keyword)' at '\(location)' is malformed; expected \(expected)"
        case .unsupportedKeyword(let keyword, let location): "keyword '\(keyword)' at '\(location)' is not supported"
        case .patternNotValid(let location, let pattern): "regular expression at '\(location)' is not valid: \(pattern)"
        case .unresolvedReference(let reference, let location): "reference '\(reference)' at '\(location)' could not be resolved"
        case .invalidSchemaType: "schema type must be a non-empty string"
        case .invalidSchemaStructure(let type): "schema for type '\(type)' is not a valid Draft 2020-12 schema"
        case .unknownRequiredVocabulary(let uri): "meta-schema requires unknown vocabulary '\(uri)'"
        }
    }
}
