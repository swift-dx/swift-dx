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

@Suite("ClickHouse bool coding")
struct BoolCodingTests {

    @Test("round-trip for false")
    func roundTripFalse() throws {
        var buffer = ByteBuffer()
        buffer.writeClickHouseBool(false)
        #expect(buffer.readableBytes == 1)
        #expect(try buffer.readClickHouseBool() == false)
    }

    @Test("round-trip for true")
    func roundTripTrue() throws {
        var buffer = ByteBuffer()
        buffer.writeClickHouseBool(true)
        #expect(buffer.readableBytes == 1)
        #expect(try buffer.readClickHouseBool() == true)
    }

    @Test("encodes false as a single zero byte")
    func falseEncodesAsZero() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseBool(false)
        #expect(buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) == 0)
    }

    @Test("encodes true as a single one byte")
    func trueEncodesAsOne() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseBool(true)
        #expect(buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) == 1)
    }

    @Test("rejects a non-zero, non-one byte")
    func rejectsInvalidRawValue() {
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt8(2))
        #expect(throws: ClickHouseError.invalidBoolean(rawValue: 2)) {
            try buffer.readClickHouseBool()
        }
    }

    @Test("reports truncation when buffer is empty")
    func truncationOnEmptyBuffer() {
        var buffer = ByteBuffer()
        #expect(throws: ClickHouseError.truncatedBuffer(needed: 1, available: 0)) {
            try buffer.readClickHouseBool()
        }
    }

}
