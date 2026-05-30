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
struct MetaSchemaValidationTests {

    @Test
    func bundledResourcesCoverEveryDialectDocument() {
        #expect(JSONSchema.draft2020MetaSchemaResources.count == 9)
    }

    @Test
    func schemaDocumentValidatesAgainstBundledMetaSchema() throws {
        let schema = try JSONSchema.compile(
            ##"{"$ref":"https://json-schema.org/draft/2020-12/schema"}"##,
            resources: JSONSchema.draft2020MetaSchemaResources
        )
        #expect(schema.validate(##"{"type":"string","minLength":1}"##).isValid)
        #expect(schema.validate(##"{"type":"object","properties":{"a":{"type":"integer"}}}"##).isValid)
        #expect(schema.validate("true").isValid)
    }

    @Test
    func malformedSchemaDocumentFailsMetaSchema() throws {
        let schema = try JSONSchema.compile(
            ##"{"$ref":"https://json-schema.org/draft/2020-12/schema"}"##,
            resources: JSONSchema.draft2020MetaSchemaResources
        )
        #expect(!schema.validate(##"{"type":123}"##).isValid)
        #expect(!schema.validate(##"{"minLength":-1}"##).isValid)
        #expect(!schema.validate(##"{"required":"notAnArray"}"##).isValid)
    }
}
