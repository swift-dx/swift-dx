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

public struct JSONSchema: Sendable {

    private let document: CompiledDocument

    init(document: CompiledDocument) {
        self.document = document
    }

    public static func compile(_ schema: [UInt8]) throws(JSONSchemaError) -> JSONSchema {
        try compile(schema, formatAssertion: false, resources: [], optionalFields: .allowed)
    }

    public static func compile(_ schema: [UInt8], formats: FormatAssertionMode) throws(JSONSchemaError) -> JSONSchema {
        try compile(schema, formatAssertion: formats == .assertion, resources: [], optionalFields: .allowed)
    }

    public static func compile(_ schema: [UInt8], optionalFields: OptionalFieldPolicy) throws(JSONSchemaError) -> JSONSchema {
        try compile(schema, formatAssertion: false, resources: [], optionalFields: optionalFields)
    }

    public static func compile(_ schema: String) throws(JSONSchemaError) -> JSONSchema {
        try compile(Array(schema.utf8))
    }

    public static func compile(_ schema: String, formats: FormatAssertionMode) throws(JSONSchemaError) -> JSONSchema {
        try compile(Array(schema.utf8), formats: formats)
    }

    public static func compile(_ schema: String, optionalFields: OptionalFieldPolicy) throws(JSONSchemaError) -> JSONSchema {
        try compile(Array(schema.utf8), optionalFields: optionalFields)
    }

    public static func compile(_ schema: [UInt8], resources: [SchemaResource]) throws(JSONSchemaError) -> JSONSchema {
        try compile(schema, formatAssertion: false, resources: resources, optionalFields: .allowed)
    }

    public static func compile(_ schema: [UInt8], formats: FormatAssertionMode, resources: [SchemaResource]) throws(JSONSchemaError) -> JSONSchema {
        try compile(schema, formatAssertion: formats == .assertion, resources: resources, optionalFields: .allowed)
    }

    public static func compile(_ schema: [UInt8], resources: [SchemaResource], optionalFields: OptionalFieldPolicy) throws(JSONSchemaError) -> JSONSchema {
        try compile(schema, formatAssertion: false, resources: resources, optionalFields: optionalFields)
    }

    public static func compile(_ schema: String, resources: [SchemaResource]) throws(JSONSchemaError) -> JSONSchema {
        try compile(Array(schema.utf8), resources: resources)
    }

    private static func compile(_ schema: [UInt8], formatAssertion: Bool, resources: [SchemaResource], optionalFields: OptionalFieldPolicy) throws(JSONSchemaError) -> JSONSchema {
        let value = try parseSchema(schema)
        let documents = try parseResources(resources)
        return JSONSchema(document: try SchemaCompiler.compile(value, formatAssertion: formatAssertion, resources: documents, optionalFields: optionalFields))
    }

    public func validate(_ instance: [UInt8]) -> SchemaValidationResult {
        do {
            return validate(try JSONParser.parse(instance, limits: .strict))
        } catch {
            return .instanceNotValidJSON(byteOffset: JSONParseFailure.byteOffset(error), hint: JSONParseFailure.hint(error))
        }
    }

    func validate(_ value: JSONValue) -> SchemaValidationResult {
        Validator.validate(value, with: document)
    }

    public func validate(_ instance: String) -> SchemaValidationResult {
        validate(Array(instance.utf8))
    }

    private static func parseSchema(_ bytes: [UInt8]) throws(JSONSchemaError) -> JSONValue {
        do {
            return try JSONParser.parse(bytes, limits: .strict)
        } catch {
            throw .schemaNotValidJSON(byteOffset: JSONParseFailure.byteOffset(error), hint: JSONParseFailure.hint(error))
        }
    }

    private static func parseResources(_ resources: [SchemaResource]) throws(JSONSchemaError) -> [ResourceDocument] {
        var documents: [ResourceDocument] = []
        for resource in resources {
            documents.append(ResourceDocument(uri: resource.uri, value: try parseSchema(resource.json)))
        }
        return documents
    }
}
