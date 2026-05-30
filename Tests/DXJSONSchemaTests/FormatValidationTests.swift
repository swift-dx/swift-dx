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
struct FormatValidationTests {

    @Test
    func formatIsAnnotationOnlyByDefault() throws {
        let schema = try JSONSchema.compile(#"{"type":"string","format":"uuid"}"#)
        #expect(schema.validate(#""not-a-uuid""#).isValid)
    }

    @Test
    func assertionModeRejectsBadUUID() throws {
        let schema = try JSONSchema.compile(#"{"type":"string","format":"uuid"}"#, formats: .assertion)
        #expect(schema.validate(##""01234567-89ab-7cde-8123-456789abcdef""##).isValid)
        #expect(!schema.validate(#""not-a-uuid""#).isValid)
    }

    @Test
    func assertionModeValidatesIPv4() throws {
        let schema = try JSONSchema.compile(#"{"format":"ipv4"}"#, formats: .assertion)
        #expect(schema.validate(#""192.168.0.1""#).isValid)
        #expect(!schema.validate(#""192.168.0.256""#).isValid)
        #expect(!schema.validate(#""192.168.0""#).isValid)
    }

    @Test
    func assertionModeValidatesDate() throws {
        let schema = try JSONSchema.compile(#"{"format":"date"}"#, formats: .assertion)
        #expect(schema.validate(#""2026-05-29""#).isValid)
        #expect(!schema.validate(#""2026-13-29""#).isValid)
        #expect(!schema.validate(#""2026-05-9""#).isValid)
    }

    @Test
    func assertionModeValidatesDateTime() throws {
        let schema = try JSONSchema.compile(#"{"format":"date-time"}"#, formats: .assertion)
        #expect(schema.validate(#""2026-05-29T12:30:00Z""#).isValid)
        #expect(!schema.validate(#""2026-05-29 12:30:00""#).isValid)
    }

    @Test
    func assertionModeValidatesEmail() throws {
        let schema = try JSONSchema.compile(#"{"format":"email"}"#, formats: .assertion)
        #expect(schema.validate(#""user@example.com""#).isValid)
        #expect(!schema.validate(#""user-at-example""#).isValid)
    }

    @Test
    func assertionModeIgnoresNonStringInstances() throws {
        let schema = try JSONSchema.compile(#"{"format":"uuid"}"#, formats: .assertion)
        #expect(schema.validate("42").isValid)
    }

    @Test
    func assertionModeValidatesDuration() throws {
        let schema = try JSONSchema.compile(#"{"format":"duration"}"#, formats: .assertion)
        #expect(schema.validate(#""P1Y2M10D""#).isValid)
        #expect(!schema.validate(#""1 year""#).isValid)
    }

    @Test
    func assertionModeValidatesRegexFormat() throws {
        let schema = try JSONSchema.compile(#"{"format":"regex"}"#, formats: .assertion)
        #expect(schema.validate(#""^[a-z]+$""#).isValid)
        #expect(!schema.validate(#""([unclosed""#).isValid)
    }
}
