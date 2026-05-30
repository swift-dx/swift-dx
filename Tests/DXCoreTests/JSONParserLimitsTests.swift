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
@testable import DXCore

@Suite
struct JSONParserLimitsTests {

    static let shallow = JSONParseLimits(maxDepth: 3, maxByteLength: 1 << 26, duplicateKeys: .lastValueWins)
    static let tiny = JSONParseLimits(maxDepth: 256, maxByteLength: 2, duplicateKeys: .lastValueWins)

    @Test
    func rejectsNestingBeyondDepthLimit() {
        let bytes = Array("[[[[]]]]".utf8)
        #expect(JSONFixtures.capturedError(bytes, limits: Self.shallow) == .found(.depthLimitExceeded(byteOffset: 3, limit: 3)))
    }

    @Test
    func acceptsNestingAtDepthLimit() throws {
        let value = try JSONParser.parse(Array("[[[]]]".utf8), limits: Self.shallow)
        #expect(value.kind == .array)
    }

    @Test
    func rejectsDocumentBeyondSizeLimit() {
        #expect(JSONFixtures.capturedError(Array("true".utf8), limits: Self.tiny) == .found(.documentTooLarge(byteLength: 4, limit: 2)))
    }

    @Test
    func lastValueWinsKeepsFinalDuplicate() {
        let object = JSONFixtures.parseObject(#"{"a":1,"a":2}"#)
        #expect(object.lookup("a") == .found(JSONFixtures.signedInteger(2)))
    }

    @Test
    func lastValueWinsCollapsesToSingleMember() {
        let object = JSONFixtures.parseObject(#"{"a":1,"a":2}"#)
        #expect(object.count == 1)
    }

    @Test
    func strictPolicyRejectsDuplicateKey() {
        let bytes = Array(#"{"a":1,"a":2}"#.utf8)
        #expect(JSONFixtures.capturedError(bytes, limits: .strict) == .found(.duplicateKey(byteOffset: 12, key: "a")))
    }
}
