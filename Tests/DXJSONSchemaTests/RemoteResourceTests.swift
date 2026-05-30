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
import DXJSONSchema

@Suite
struct RemoteResourceTests {

    @Test
    func crossDocumentRefResolvesAgainstProvidedResource() throws {
        let resource = SchemaResource(uri: "https://ext.example/integer.json", json: ##"{"type":"integer"}"##)
        let schema = try JSONSchema.compile(##"{"$ref":"https://ext.example/integer.json"}"##, resources: [resource])
        #expect(schema.validate("5").isValid)
        #expect(!schema.validate(##""x""##).isValid)
    }

    @Test
    func crossDocumentPointerFragmentResolvesAgainstResourceBase() throws {
        let resource = SchemaResource(uri: "https://ext.example/defs.json", json: ##"{"$defs":{"positive":{"type":"integer","minimum":1}}}"##)
        let schema = try JSONSchema.compile(##"{"$ref":"https://ext.example/defs.json#/$defs/positive"}"##, resources: [resource])
        #expect(schema.validate("3").isValid)
        #expect(!schema.validate("0").isValid)
    }

    @Test
    func resourcesMayReferenceOneAnother() throws {
        let leaf = SchemaResource(uri: "https://ext.example/leaf.json", json: ##"{"$id":"https://ext.example/leaf.json","type":"string"}"##)
        let bridge = SchemaResource(uri: "https://ext.example/bridge.json", json: ##"{"$id":"https://ext.example/bridge.json","$ref":"leaf.json"}"##)
        let schema = try JSONSchema.compile(##"{"$ref":"https://ext.example/bridge.json"}"##, resources: [bridge, leaf])
        #expect(schema.validate(##""hello""##).isValid)
        #expect(!schema.validate("5").isValid)
    }

    @Test
    func dynamicAnchorInResourceResolvesAcrossDocuments() throws {
        let tree = SchemaResource(uri: "https://ext.example/tree.json", json: ##"{"$id":"https://ext.example/tree.json","$dynamicAnchor":"node","type":"object","properties":{"children":{"type":"array","items":{"$dynamicRef":"#node"}}}}"##)
        let schema = try JSONSchema.compile(##"{"$ref":"https://ext.example/tree.json"}"##, resources: [tree])
        #expect(schema.validate(##"{"children":[{"children":[]}]}"##).isValid)
        #expect(!schema.validate(##"{"children":[5]}"##).isValid)
    }

    @Test
    func missingResourceStillThrows() {
        #expect(throws: JSONSchemaError.self) {
            try JSONSchema.compile(##"{"$ref":"https://ext.example/absent.json"}"##, resources: [])
        }
    }
}
