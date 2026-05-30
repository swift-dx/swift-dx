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

import Testing
import NIOCore
import DXJSONSchema

@Suite
struct PayloadAndContentTests {

    struct Person: Encodable, Sendable {

        let name: String
        let age: Int
    }

    static let personSchema = #"{"type":"object","required":["name","age"],"properties":{"name":{"type":"string"},"age":{"type":"integer","minimum":0}}}"#

    @Test
    func validatesByteBufferInstance() throws {
        let schema = try JSONSchema.compile(Self.personSchema)
        let buffer = ByteBuffer(string: #"{"name":"Ada","age":36}"#)
        #expect(schema.validate(buffer).isValid)
    }

    @Test
    func compilesFromByteBufferSchema() throws {
        let schemaBuffer = ByteBuffer(string: #"{"type":"integer","minimum":1}"#)
        let schema = try JSONSchema.compile(schemaBuffer)
        #expect(schema.validate("5").isValid)
        #expect(!schema.validate("0").isValid)
    }

    @Test
    func validatesEncodableInstance() throws {
        let schema = try JSONSchema.compile(Self.personSchema)
        #expect(schema.validate(encoding: Person(name: "Ada", age: 36)).isValid)
        #expect(!schema.validate(encoding: Person(name: "Ada", age: -1)).isValid)
    }

    @Test
    func validatesSequenceBatch() throws {
        let schema = try JSONSchema.compile(#"{"type":"integer"}"#)
        let instances: [[UInt8]] = [Array("1".utf8), Array(#""x""#.utf8), Array("3".utf8)]
        let results = schema.validate(batch: instances)
        #expect(results.count == 3)
        #expect(results[0].isValid)
        #expect(!results[1].isValid)
        #expect(results[2].isValid)
    }

    @Test
    func contentKeywordsAreAnnotationOnly() throws {
        let schema = try JSONSchema.compile(#"{"type":"string","contentEncoding":"base64","contentMediaType":"application/json","contentSchema":{"type":"object"}}"#)
        #expect(schema.validate(#""anything at all""#).isValid)
        #expect(schema.validate(#""not%%%base64""#).isValid)
        #expect(!schema.validate("42").isValid)
    }
}
