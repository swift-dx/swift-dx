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
struct IdResolutionTests {

    @Test
    func refByAbsoluteIdResolves() throws {
        let schema = try JSONSchema.compile(##"{"$id":"https://example.com/root","properties":{"a":{"$ref":"https://example.com/defs"}},"$defs":{"x":{"$id":"https://example.com/defs","type":"integer"}}}"##)
        #expect(schema.validate(##"{"a":5}"##).isValid)
        #expect(!schema.validate(##"{"a":"s"}"##).isValid)
    }

    @Test
    func relativeRefResolvesAgainstBase() throws {
        let schema = try JSONSchema.compile(##"{"$id":"https://example.com/root","properties":{"a":{"$ref":"sub"}},"$defs":{"x":{"$id":"https://example.com/sub","type":"string"}}}"##)
        #expect(schema.validate(##"{"a":"hi"}"##).isValid)
        #expect(!schema.validate(##"{"a":5}"##).isValid)
    }

    @Test
    func anchorScopedToNestedId() throws {
        let schema = try JSONSchema.compile(##"{"$defs":{"x":{"$id":"https://example.com/t","$anchor":"Item","type":"integer"}},"properties":{"a":{"$ref":"https://example.com/t#Item"}}}"##)
        #expect(schema.validate(##"{"a":5}"##).isValid)
        #expect(!schema.validate(##"{"a":"s"}"##).isValid)
    }

    @Test
    func recursiveByRootId() throws {
        let schema = try JSONSchema.compile(##"{"$id":"https://example.com/tree","type":"object","additionalProperties":false,"properties":{"v":{"type":"integer"},"child":{"$ref":"https://example.com/tree"}}}"##)
        #expect(schema.validate(##"{"v":1,"child":{"v":2,"child":{"v":3}}}"##).isValid)
        #expect(!schema.validate(##"{"v":1,"child":{"bad":1}}"##).isValid)
    }
}
