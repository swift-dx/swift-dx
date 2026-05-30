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
struct JSONStringTests {

    static let samples = ["", "a", "hello", "héllo", "🎉", "e\u{0301}", "tab\tnewline\n", "\u{0000}\u{001f}", "ключ", "二維碼", String(repeating: "x", count: 500)]

    func slice(of text: String, padding: Int = 3) -> JSONString {
        var bytes = Array(repeating: UInt8(ascii: "#"), count: padding)
        bytes.append(contentsOf: text.utf8)
        bytes.append(contentsOf: Array(repeating: UInt8(ascii: "#"), count: padding))
        return .slice(source: bytes, offset: padding, length: Array(text.utf8).count)
    }

    @Test
    func sliceEqualsMaterializedForIdenticalBytes() {
        for sample in Self.samples {
            #expect(slice(of: sample) == JSONString(sample))
            #expect(JSONString(sample) == slice(of: sample))
        }
    }

    @Test
    func sliceAndMaterializedHashIdentically() {
        for sample in Self.samples {
            #expect(slice(of: sample).hashValue == JSONString(sample).hashValue)
        }
    }

    @Test
    func setDeduplicatesAcrossBackings() {
        for sample in Self.samples {
            let bucket: Set<JSONString> = [slice(of: sample), JSONString(sample), slice(of: sample, padding: 7)]
            #expect(bucket.count == 1)
        }
    }

    @Test
    func distinctContentIsNotEqual() {
        #expect(slice(of: "alpha") != JSONString("beta"))
        #expect(slice(of: "alpha") != slice(of: "alphab"))
        #expect(JSONString("") != JSONString(" "))
    }

    @Test
    func valueRoundTrips() {
        for sample in Self.samples {
            #expect(slice(of: sample).value == sample)
            #expect(JSONString(sample).value == sample)
        }
    }

    @Test
    func scalarCountMatchesUnicodeScalars() {
        for sample in Self.samples {
            #expect(slice(of: sample).scalarCount == sample.unicodeScalars.count)
            #expect(JSONString(sample).scalarCount == sample.unicodeScalars.count)
        }
    }

    @Test
    func equalsStringComparesContent() {
        #expect(slice(of: "needle").equalsString("needle"))
        #expect(!slice(of: "needle").equalsString("needles"))
        #expect(!slice(of: "needle").equalsString("haystack"))
        #expect(JSONString("二維碼").equalsString("二維碼"))
    }

    @Test
    func emptySliceAtBufferStart() {
        let empty = JSONString.slice(source: [], offset: 0, length: 0)
        #expect(empty == JSONString(""))
        #expect(empty.scalarCount == 0)
        #expect(empty.value.isEmpty)
    }
}
