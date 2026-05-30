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
struct AssertionValidationTests {

    @Test
    func typeStringAcceptsStringRejectsNumber() throws {
        let schema = try JSONSchema.compile(#"{"type":"string"}"#)
        #expect(schema.validate(#""hello""#).isValid)
        #expect(!schema.validate("5").isValid)
    }

    @Test
    func maxLengthBeyondIntMaxCompilesAndIsEffectivelyUnbounded() throws {
        let schema = try JSONSchema.compile(##"{"type":"string","maxLength":9223372036854775808}"##)
        #expect(schema.validate(##""hello""##).isValid)
    }

    @Test
    func minLengthBeyondIntMaxRejectsOrdinaryStrings() throws {
        let schema = try JSONSchema.compile(##"{"type":"string","minLength":9223372036854775808}"##)
        #expect(!schema.validate(##""hello""##).isValid)
    }

    @Test
    func typeIntegerAcceptsIntegralDoubleRejectsFraction() throws {
        let schema = try JSONSchema.compile(#"{"type":"integer"}"#)
        #expect(schema.validate("5").isValid)
        #expect(schema.validate("5.0").isValid)
        #expect(!schema.validate("5.5").isValid)
    }

    @Test
    func typeNumberAcceptsIntegerAndFraction() throws {
        let schema = try JSONSchema.compile(#"{"type":"number"}"#)
        #expect(schema.validate("5").isValid)
        #expect(schema.validate("5.5").isValid)
        #expect(!schema.validate(#""x""#).isValid)
    }

    @Test
    func typeNullDistinctFromBoolean() throws {
        let schema = try JSONSchema.compile(#"{"type":"null"}"#)
        #expect(schema.validate("null").isValid)
        #expect(!schema.validate("false").isValid)
    }

    @Test
    func multipleTypesAccepted() throws {
        let schema = try JSONSchema.compile(#"{"type":["string","null"]}"#)
        #expect(schema.validate(#""x""#).isValid)
        #expect(schema.validate("null").isValid)
        #expect(!schema.validate("5").isValid)
    }

    @Test
    func enumRestrictsValues() throws {
        let schema = try JSONSchema.compile(#"{"enum":["red","green",3]}"#)
        #expect(schema.validate(#""red""#).isValid)
        #expect(schema.validate("3").isValid)
        #expect(!schema.validate(#""blue""#).isValid)
    }

    @Test
    func constRequiresExactValue() throws {
        let schema = try JSONSchema.compile(#"{"const":{"a":1}}"#)
        #expect(schema.validate(#"{"a":1}"#).isValid)
        #expect(!schema.validate(#"{"a":2}"#).isValid)
    }

    @Test
    func constMatchesNumericallyAcrossForms() throws {
        let schema = try JSONSchema.compile(#"{"const":1}"#)
        #expect(schema.validate("1.0").isValid)
    }

    @Test
    func maximumAndMinimumBounds() throws {
        let schema = try JSONSchema.compile(#"{"minimum":1,"maximum":10}"#)
        #expect(schema.validate("1").isValid)
        #expect(schema.validate("10").isValid)
        #expect(!schema.validate("0").isValid)
        #expect(!schema.validate("11").isValid)
    }

    @Test
    func exclusiveBounds() throws {
        let schema = try JSONSchema.compile(#"{"exclusiveMinimum":1,"exclusiveMaximum":10}"#)
        #expect(!schema.validate("1").isValid)
        #expect(schema.validate("2").isValid)
        #expect(!schema.validate("10").isValid)
    }

    @Test
    func multipleOfInteger() throws {
        let schema = try JSONSchema.compile(#"{"multipleOf":3}"#)
        #expect(schema.validate("9").isValid)
        #expect(!schema.validate("10").isValid)
    }

    @Test
    func multipleOfDecimal() throws {
        let schema = try JSONSchema.compile(#"{"multipleOf":0.5}"#)
        #expect(schema.validate("1.5").isValid)
        #expect(!schema.validate("1.25").isValid)
    }

    @Test
    func multipleOfAcceptsValueWhoseQuotientOverflows() throws {
        let schema = try JSONSchema.compile(#"{"type":"integer","multipleOf":0.5}"#)
        #expect(schema.validate("1e308").isValid)
    }

    @Test
    func maximumOnLargeIntegerIsExact() throws {
        let schema = try JSONSchema.compile(#"{"maximum":9223372036854775807}"#)
        #expect(schema.validate("9223372036854775807").isValid)
        #expect(!schema.validate("9223372036854775808").isValid)
    }

    @Test
    func stringLengthBounds() throws {
        let schema = try JSONSchema.compile(#"{"type":"string","minLength":2,"maxLength":4}"#)
        #expect(schema.validate(#""ab""#).isValid)
        #expect(!schema.validate(#""a""#).isValid)
        #expect(!schema.validate(#""abcde""#).isValid)
    }

    @Test
    func arrayItemBounds() throws {
        let schema = try JSONSchema.compile(#"{"type":"array","minItems":1,"maxItems":2}"#)
        #expect(schema.validate("[1]").isValid)
        #expect(!schema.validate("[]").isValid)
        #expect(!schema.validate("[1,2,3]").isValid)
    }

    @Test
    func uniqueItemsRejectsDuplicates() throws {
        let schema = try JSONSchema.compile(#"{"uniqueItems":true}"#)
        #expect(schema.validate("[1,2,3]").isValid)
        #expect(!schema.validate("[1,2,1]").isValid)
        #expect(!schema.validate(#"[{"a":1},{"a":1}]"#).isValid)
    }

    @Test
    func requiredReportsEveryMissingProperty() throws {
        let schema = try JSONSchema.compile(#"{"required":["a","b","c"]}"#)
        let result = schema.validate(#"{"a":1}"#)
        #expect(result.violations.count == 2)
    }

    @Test
    func propertyCountBounds() throws {
        let schema = try JSONSchema.compile(#"{"minProperties":1,"maxProperties":2}"#)
        #expect(schema.validate(#"{"a":1}"#).isValid)
        #expect(!schema.validate("{}").isValid)
        #expect(!schema.validate(#"{"a":1,"b":2,"c":3}"#).isValid)
    }
}
