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
struct JSONScanTests {

    @Test
    func jsonScan_fieldExtractsStringValue() {
        let bytes = Array(#"{"nonce":"abc123","other":1}"#.utf8)
        let key = Array(#""nonce""#.utf8)
        #expect(JSONScan.field(bytes, start: 0, end: bytes.count, key: key) == "abc123")
    }

    @Test
    func jsonScan_fieldReturnsEmptyWhenKeyMissing() {
        let bytes = Array(#"{"other":1}"#.utf8)
        let key = Array(#""nonce""#.utf8)
        #expect(JSONScan.field(bytes, start: 0, end: bytes.count, key: key) == "")
    }

    @Test
    func jsonScan_fieldReturnsEmptyOnEscapeSequence() {
        let bytes = Array(#"{"nonce":"a\b"}"#.utf8)
        let key = Array(#""nonce""#.utf8)
        #expect(JSONScan.field(bytes, start: 0, end: bytes.count, key: key) == "")
    }

    @Test
    func jsonScan_fieldHandlesWhitespaceBetweenKeyAndColon() {
        let bytes = Array(#"{"nonce"  :  "ok"}"#.utf8)
        let key = Array(#""nonce""#.utf8)
        #expect(JSONScan.field(bytes, start: 0, end: bytes.count, key: key) == "ok")
    }
}
