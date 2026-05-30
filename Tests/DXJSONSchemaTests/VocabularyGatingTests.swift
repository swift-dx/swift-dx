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
struct VocabularyGatingTests {

    static let noValidationDialect = SchemaResource(
        uri: "https://test.swiftdx/no-validation",
        json: ##"{"$id":"https://test.swiftdx/no-validation","$schema":"https://json-schema.org/draft/2020-12/schema","$vocabulary":{"https://json-schema.org/draft/2020-12/vocab/core":true,"https://json-schema.org/draft/2020-12/vocab/applicator":true},"$dynamicAnchor":"meta","allOf":[{"$ref":"https://json-schema.org/draft/2020-12/meta/core"},{"$ref":"https://json-schema.org/draft/2020-12/meta/applicator"}]}"##
    )

    static let unknownRequiredDialect = SchemaResource(
        uri: "https://test.swiftdx/unknown-required",
        json: ##"{"$id":"https://test.swiftdx/unknown-required","$schema":"https://json-schema.org/draft/2020-12/schema","$vocabulary":{"https://json-schema.org/draft/2020-12/vocab/core":true,"https://test.swiftdx/vocab/made-up":true},"$dynamicAnchor":"meta","allOf":[{"$ref":"https://json-schema.org/draft/2020-12/meta/core"}]}"##
    )

    static func resources(with dialect: SchemaResource) -> [SchemaResource] {
        JSONSchema.draft2020MetaSchemaResources + [dialect]
    }

    @Test
    func validationVocabularyAbsentDisablesAssertion() throws {
        let schema = try JSONSchema.compile(
            ##"{"$schema":"https://test.swiftdx/no-validation","minLength":5}"##,
            resources: Self.resources(with: Self.noValidationDialect)
        )
        #expect(schema.validate(##""ab""##).isValid)
    }

    @Test
    func applicatorVocabularyStillAppliesWithoutValidation() throws {
        let schema = try JSONSchema.compile(
            ##"{"$schema":"https://test.swiftdx/no-validation","properties":{"banned":false}}"##,
            resources: Self.resources(with: Self.noValidationDialect)
        )
        #expect(schema.validate(##"{"allowed":1}"##).isValid)
        #expect(!schema.validate(##"{"banned":1}"##).isValid)
    }

    @Test
    func standardDialectStillEnforcesValidation() throws {
        let schema = try JSONSchema.compile(##"{"minLength":5}"##)
        #expect(!schema.validate(##""ab""##).isValid)
        #expect(schema.validate(##""abcde""##).isValid)
    }

    @Test
    func unknownRequiredVocabularyFailsCompilation() {
        #expect(throws: JSONSchemaError.self) {
            try JSONSchema.compile(
                ##"{"$schema":"https://test.swiftdx/unknown-required","type":"string"}"##,
                resources: Self.resources(with: Self.unknownRequiredDialect)
            )
        }
    }
}
