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

@Suite("ClickHouse UVarInt coding")
struct UVarIntCodingTests {

    @Test(
        "round-trip across boundary values",
        arguments: [
            UInt64(0),
            UInt64(1),
            UInt64(0x7F),
            UInt64(0x80),
            UInt64(0x3FFF),
            UInt64(0x4000),
            UInt64(0x1FFFFF),
            UInt64(0x200000),
            UInt64(0xFFFFFFFF),
            UInt64(0x100000000),
            UInt64(0xFFFFFFFFFFFFFFFF),
        ]
    )
    func roundTrip(_ value: UInt64) throws {
        var buffer = ByteBuffer()
        buffer.writeClickHouseUVarInt(value)
        #expect(try buffer.readClickHouseUVarInt() == value)
        #expect(buffer.readableBytes == 0)
    }

    @Test("encodes a single byte for values below 0x80")
    func singleByteForSmallValues() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseUVarInt(0x7F)
        #expect(buffer.readableBytes == 1)
    }

    @Test("uses ten bytes for UInt64.max")
    func tenBytesForMax() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseUVarInt(UInt64.max)
        #expect(buffer.readableBytes == 10)
    }

    @Test("matches a known wire encoding for value 300")
    func knownWireEncoding() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseUVarInt(300)
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
        #expect(bytes == [0xAC, 0x02])
    }

    @Test("throws uvarintIncomplete on empty buffer")
    func incompleteOnEmptyBuffer() {
        var buffer = ByteBuffer()
        #expect(throws: ClickHouseError.uvarintIncomplete) {
            try buffer.readClickHouseUVarInt()
        }
    }

    @Test("throws uvarintIncomplete when continuation bit set with no more bytes")
    func incompleteOnTruncatedContinuation() {
        var buffer = ByteBuffer()
        buffer.writeBytes([UInt8(0x80)])
        #expect(throws: ClickHouseError.uvarintIncomplete) {
            try buffer.readClickHouseUVarInt()
        }
    }

    @Test("throws uvarintOverflow on eleven continuation bytes")
    func overflowOnElevenBytes() {
        var buffer = ByteBuffer()
        buffer.writeBytes(Array(repeating: UInt8(0x80), count: 10))
        buffer.writeBytes([UInt8(0x01)])
        #expect(throws: ClickHouseError.uvarintOverflow) {
            try buffer.readClickHouseUVarInt()
        }
    }

    @Test("throws uvarintOverflow when tenth byte exceeds one")
    func overflowOnInvalidTenthByte() {
        var buffer = ByteBuffer()
        buffer.writeBytes(Array(repeating: UInt8(0x80), count: 9))
        buffer.writeBytes([UInt8(0x02)])
        #expect(throws: ClickHouseError.uvarintOverflow) {
            try buffer.readClickHouseUVarInt()
        }
    }

    @Test("multiple uvarints can be packed in a single buffer")
    func packedSequence() throws {
        var buffer = ByteBuffer()
        let values: [UInt64] = [0, 1, 127, 128, 16384, 0xFFFFFFFF]
        for value in values {
            buffer.writeClickHouseUVarInt(value)
        }
        for expected in values {
            #expect(try buffer.readClickHouseUVarInt() == expected)
        }
        #expect(buffer.readableBytes == 0)
    }

}
