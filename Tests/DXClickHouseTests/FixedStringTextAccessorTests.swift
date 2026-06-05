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

import DXClickHouse
import Testing

// A FixedString(N) column is right-padded with zero bytes on the wire, so a
// decoded ClickHouseFixedString carries those trailing zeros in `bytes`.
// Recovering the stored text by decoding `bytes` directly leaves embedded
// NUL characters that silently break equality, hashing, and logging. The
// `text` accessor drops the trailing zero padding and decodes the content
// as UTF-8, which is what a fixed-width identifier or code column needs.
@Suite("ClickHouseFixedString exposes its content as clean text")
struct FixedStringTextAccessorTests {

    @Test("trailing zero padding is dropped")
    func paddingDropped() {
        let padded = ClickHouseFixedString(bytes: Array("abc".utf8) + Array(repeating: 0, count: 7), length: 10)
        #expect(padded.text == "abc")
    }

    @Test("a fixed-width identifier with no padding survives intact")
    func fullWidthIntact() {
        let identifier = String(repeating: "A", count: 44)
        let value = ClickHouseFixedString(identifier, length: 44)
        #expect(value.text == identifier)
    }

    @Test("an all-zero slot is empty text")
    func allZeroIsEmpty() {
        let blank = ClickHouseFixedString(bytes: Array(repeating: 0, count: 8), length: 8)
        #expect(blank.text == "")
    }

    @Test("the raw padded bytes remain available for binary content")
    func rawBytesPreserved() {
        let padded = ClickHouseFixedString(bytes: Array("id".utf8) + Array(repeating: 0, count: 6), length: 8)
        #expect(padded.bytes.count == 8)
        #expect(padded.text == "id")
    }
}
