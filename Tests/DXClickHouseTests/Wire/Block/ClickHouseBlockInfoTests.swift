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

@Suite("ClickHouse block info")
struct ClickHouseBlockInfoTests {

    @Test("default block info round-trips faithfully")
    func defaultRoundTrip() throws {
        let original = ClickHouseBlockInfo()
        var buffer = ByteBuffer()
        original.encode(into: &buffer)
        let decoded = try ClickHouseBlockInfo.decode(from: &buffer)
        #expect(decoded == original)
        #expect(decoded.isOverflows == false)
        #expect(decoded.bucketNumber == -1)
        #expect(buffer.readableBytes == 0)
    }

    @Test("non-default block info round-trips faithfully")
    func nonDefaultRoundTrip() throws {
        let original = ClickHouseBlockInfo(isOverflows: true, bucketNumber: 7)
        var buffer = ByteBuffer()
        original.encode(into: &buffer)
        let decoded = try ClickHouseBlockInfo.decode(from: &buffer)
        #expect(decoded == original)
    }

    @Test("encoded form is exactly the field-tagged TLV layout")
    func encodedTLVLayout() {
        let info = ClickHouseBlockInfo(isOverflows: true, bucketNumber: 0)
        var buffer = ByteBuffer()
        info.encode(into: &buffer)
        // UVarInt(1) + Bool(1) + UVarInt(2) + Int32 LE + UVarInt(0)
        // = 1 + 1 + 1 + 4 + 1 = 8 bytes
        #expect(buffer.readableBytes == 8)
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
        #expect(bytes[0] == 0x01)  // field 1 marker
        #expect(bytes[1] == 0x01)  // isOverflows = true
        #expect(bytes[2] == 0x02)  // field 2 marker
        // bytes[3..6] = bucketNumber (Int32 LE)
        #expect(bytes[7] == 0x00)  // terminator
    }

    @Test("an unknown field number surfaces a typed error rather than silently skipping")
    func unknownFieldRejected() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseUVarInt(99)
        #expect(throws: ClickHouseError.unknownBlockInfoField(99)) {
            try ClickHouseBlockInfo.decode(from: &buffer)
        }
    }

    @Test("a truncated TLV stream surfaces a typed truncation error")
    func truncatedStreamRejected() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseUVarInt(1)
        // missing the bool byte that should follow
        #expect(throws: ClickHouseError.self) {
            try ClickHouseBlockInfo.decode(from: &buffer)
        }
    }

}
