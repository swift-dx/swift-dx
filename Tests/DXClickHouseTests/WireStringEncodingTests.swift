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

// ClickHouseWire.writeString is the universal length-prefixed string
// serializer on the INSERT hot path (one call per String/JSON value,
// column name, and type name). It appends the UTF-8 view directly rather
// than materializing an intermediate array. These tests pin the exact
// wire bytes so that performance-motivated change cannot silently alter
// the on-wire format: a UVarInt byte length followed by the raw UTF-8
// bytes.
@Suite("ClickHouseWire.writeString emits a UVarInt length prefix then raw UTF-8")
struct WireStringEncodingTests {

    // Independent reference: the length as a UVarInt, then the raw UTF-8
    // bytes. Computed without touching the production helper so it stays
    // an external oracle for the wire contract.
    private func reference(_ value: String) -> [UInt8] {
        let utf8 = Array(value.utf8)
        var bytes: [UInt8] = []
        var length = UInt64(utf8.count)
        while length >= 0x80 {
            bytes.append(UInt8(length & 0x7F) | 0x80)
            length >>= 7
        }
        bytes.append(UInt8(length))
        bytes.append(contentsOf: utf8)
        return bytes
    }

    private func encoded(_ value: String) -> [UInt8] {
        var output: [UInt8] = []
        ClickHouseWire.writeString(value, into: &output)
        return output
    }

    @Test("an empty string is a single zero length byte")
    func emptyString() {
        #expect(encoded("") == [0])
    }

    @Test("a short ASCII string is length then bytes")
    func shortAscii() {
        #expect(encoded("ab") == [2, 0x61, 0x62])
    }

    @Test("a multibyte UTF-8 string uses the byte length, not the character count")
    func multibyte() {
        // "é" is 2 UTF-8 bytes; "🍵" is 4.
        #expect(encoded("é") == [2, 0xC3, 0xA9])
        let tea = encoded("🍵")
        #expect(tea.first == 4)
        #expect(Array(tea.dropFirst()) == Array("🍵".utf8))
    }

    @Test("a string of 200 bytes uses a two-byte UVarInt length prefix")
    func twoByteLengthPrefix() {
        let value = String(repeating: "x", count: 200)
        let output = encoded(value)
        // 200 = 0xC8 -> UVarInt [0xC8, 0x01], then 200 'x' bytes.
        #expect(Array(output.prefix(2)) == [0xC8, 0x01])
        #expect(output.count == 202)
    }

    @Test("the encoding matches the independent reference across varied inputs")
    func matchesReference() {
        let samples = [
            "",
            "a",
            "created_at",
            "é-accent",
            "🍵🍵🍵 tea",
            String(repeating: "z", count: 130),
            "embedded\u{0}null",
            "tab\tand\nnewline",
        ]
        for sample in samples {
            #expect(encoded(sample) == reference(sample), "mismatch for \(sample.debugDescription)")
        }
    }
}
