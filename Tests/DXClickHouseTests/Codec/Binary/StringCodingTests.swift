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

@testable import DXClickHouse
import NIOCore
import Testing

@Suite("ClickHouse string coding")
struct StringCodingTests {

    @Test(
        "round-trip across representative payloads",
        arguments: [
            "",
            "a",
            "ClickHouse",
            String(repeating: "x", count: 127),
            String(repeating: "x", count: 128),
            String(repeating: "x", count: 16_384),
            "Привет, мир",
            "新西兰房地产",
            "emoji 🚀🇳🇿",
        ]
    )
    func roundTrip(_ value: String) throws {
        var buffer = ByteBuffer()
        buffer.writeClickHouseString(value)
        #expect(try buffer.readClickHouseString() == value)
        #expect(buffer.readableBytes == 0)
    }

    @Test("empty string is encoded as a single zero byte")
    func emptyStringIsZeroByte() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseString("")
        #expect(buffer.readableBytes == 1)
        #expect(buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) == 0)
    }

    @Test("encodes utf-8 byte length, not character count")
    func utf8ByteLengthIsUsed() throws {
        var buffer = ByteBuffer()
        buffer.writeClickHouseString("á")
        let length = try buffer.readClickHouseUVarInt()
        #expect(length == 2)
    }

    @Test("packs multiple strings sequentially in the same buffer")
    func packedSequence() throws {
        var buffer = ByteBuffer()
        let values = ["one", "", "two", "three"]
        for value in values {
            buffer.writeClickHouseString(value)
        }
        for expected in values {
            #expect(try buffer.readClickHouseString() == expected)
        }
        #expect(buffer.readableBytes == 0)
    }

    @Test("rejects a length prefix that exceeds the remaining bytes")
    func rejectsLengthBeyondBuffer() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseUVarInt(64)
        buffer.writeBytes(Array("short".utf8))
        #expect(throws: ClickHouseError.self) {
            try buffer.readClickHouseString()
        }
    }

    @Test("rejects a length prefix that exceeds the caller-supplied limit")
    func rejectsLengthBeyondLimit() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseString(String(repeating: "x", count: 1024))
        #expect(throws: ClickHouseError.self) {
            try buffer.readClickHouseString(maxLength: 16)
        }
    }

    @Test("default limit blocks an absurd length prefix without allocating")
    func defaultLimitBlocksAbsurdLength() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseUVarInt(UInt64.max)
        #expect(throws: ClickHouseError.self) {
            try buffer.readClickHouseString()
        }
    }

}
