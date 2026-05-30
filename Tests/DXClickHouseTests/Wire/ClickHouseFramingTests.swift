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

@Suite("ClickHouse framing helper")
struct ClickHouseFramingTests {

    @Test("a complete packet frames as .complete and consumes its bytes")
    func completePacketFrames() throws {
        var buffer = ByteBuffer()
        ClickHouseServerPacketType.pong.write(into: &buffer)

        let result = try ClickHouseFraming.tryFrame(from: &buffer) { buf in
            try ClickHouseServerPacketReader.read(from: &buf, revision: 54_478)
        }
        guard case .complete(let packet) = result else {
            Issue.record("expected .complete")
            return
        }
        guard case .pong = packet else {
            Issue.record("expected .pong, got \(packet)")
            return
        }
        #expect(buffer.readableBytes == 0)
    }

    @Test("an empty buffer returns .needsMoreBytes without consuming anything")
    func emptyBufferAsksForMoreBytes() throws {
        var buffer = ByteBuffer()
        let savedIndex = buffer.readerIndex

        let result = try ClickHouseFraming.tryFrame(from: &buffer) { buf in
            try ClickHouseServerPacketReader.read(from: &buf, revision: 54_478)
        }
        guard case .needsMoreBytes = result else {
            Issue.record("expected .needsMoreBytes")
            return
        }
        #expect(buffer.readerIndex == savedIndex)
    }

    @Test("a truncated UVarInt continuation triggers .needsMoreBytes and rewinds")
    func truncatedUVarIntRewinds() throws {
        var buffer = ByteBuffer()
        buffer.writeBytes([UInt8(0x80)])
        let savedIndex = buffer.readerIndex

        let result = try ClickHouseFraming.tryFrame(from: &buffer) { buf in
            try buf.readClickHouseUVarInt()
        }
        guard case .needsMoreBytes = result else {
            Issue.record("expected .needsMoreBytes for truncated uvarint")
            return
        }
        #expect(buffer.readerIndex == savedIndex)
    }

    @Test("a string with declared length exceeding available bytes triggers .needsMoreBytes and rewinds")
    func truncatedStringRewinds() throws {
        var buffer = ByteBuffer()
        buffer.writeClickHouseUVarInt(100)
        buffer.writeBytes("Click".utf8)
        let savedIndex = buffer.readerIndex

        let result = try ClickHouseFraming.tryFrame(from: &buffer) { buf in
            try buf.readClickHouseString()
        }
        guard case .needsMoreBytes = result else {
            Issue.record("expected .needsMoreBytes for truncated string")
            return
        }
        #expect(buffer.readerIndex == savedIndex)
    }

    @Test("a fixed-width integer with insufficient bytes triggers .needsMoreBytes and rewinds")
    func truncatedFixedWidthIntegerRewinds() throws {
        var buffer = ByteBuffer()
        buffer.writeBytes([UInt8(0x01), UInt8(0x02), UInt8(0x03)])
        let savedIndex = buffer.readerIndex

        let result = try ClickHouseFraming.tryFrame(from: &buffer) { buf in
            try buf.readClickHouseFixedWidthInteger(Int64.self)
        }
        guard case .needsMoreBytes = result else {
            Issue.record("expected .needsMoreBytes for truncated Int64")
            return
        }
        #expect(buffer.readerIndex == savedIndex)
    }

    @Test("a malformed UVarInt (overflow) propagates as a fatal error")
    func uvarintOverflowIsFatal() {
        var buffer = ByteBuffer()
        buffer.writeBytes(Array(repeating: UInt8(0x80), count: 10))
        buffer.writeBytes([UInt8(0x01)])

        #expect(throws: ClickHouseError.uvarintOverflow) {
            try ClickHouseFraming.tryFrame(from: &buffer) { buf in
                try buf.readClickHouseUVarInt()
            }
        }
    }

    @Test("an invalid bool byte propagates as a fatal error")
    func invalidBoolIsFatal() {
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt8(5))

        #expect(throws: ClickHouseError.self) {
            try ClickHouseFraming.tryFrame(from: &buffer) { buf in
                try buf.readClickHouseBool()
            }
        }
    }

    @Test("a string-length declaration that exceeds the configured cap is fatal, not recoverable")
    func absurdStringLengthIsFatal() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseUVarInt(UInt64.max)

        #expect(throws: ClickHouseError.self) {
            try ClickHouseFraming.tryFrame(from: &buffer) { buf in
                try buf.readClickHouseString()
            }
        }
    }

    @Test("an unknown server packet marker propagates as fatal, not recoverable")
    func unknownServerMarkerIsFatal() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseUVarInt(200)

        #expect(throws: ClickHouseError.unknownServerPacketType(rawValue: 200)) {
            try ClickHouseFraming.tryFrame(from: &buffer) { buf in
                try ClickHouseServerPacketReader.read(from: &buf, revision: 54_478)
            }
        }
    }

    @Test("a packet split at any byte boundary frames after the second half is appended")
    func splitAtArbitraryBoundary() throws {
        let exception = ClickHouseServerExceptionPacket(
            code: 42,
            name: "DB::Test",
            message: "split at every byte",
            stackTrace: "frame1\nframe2\nframe3",
            nested: .none
        )
        var fullBuffer = ByteBuffer()
        ClickHouseServerPacketType.exception.write(into: &fullBuffer)
        exception.encode(into: &fullBuffer)

        let allBytes = fullBuffer.getBytes(at: fullBuffer.readerIndex, length: fullBuffer.readableBytes) ?? []
        #expect(allBytes.count > 4)

        for splitAt in 1..<allBytes.count {
            var buffer = ByteBuffer()
            buffer.writeBytes(Array(allBytes[0..<splitAt]))
            let savedIndex = buffer.readerIndex

            let partial = try ClickHouseFraming.tryFrame(from: &buffer) { buf in
                try ClickHouseServerPacketReader.read(from: &buf, revision: 54_478)
            }
            guard case .needsMoreBytes = partial else {
                Issue.record("split at \(splitAt) expected .needsMoreBytes")
                continue
            }
            #expect(buffer.readerIndex == savedIndex, "split at \(splitAt) did not rewind reader")

            buffer.writeBytes(Array(allBytes[splitAt..<allBytes.count]))
            let complete = try ClickHouseFraming.tryFrame(from: &buffer) { buf in
                try ClickHouseServerPacketReader.read(from: &buf, revision: 54_478)
            }
            guard case .complete(.exception(let decoded)) = complete else {
                Issue.record("split at \(splitAt) expected .complete(.exception)")
                continue
            }
            #expect(decoded == exception, "split at \(splitAt) decoded mismatched exception")
            #expect(buffer.readableBytes == 0, "split at \(splitAt) left bytes in buffer")
        }
    }

    @Test("a compressed frame split across reads is recoverable, not fatal")
    func compressionFrameTruncatedIsRecoverable() throws {
        // Build a real compressed frame, then feed it byte-by-byte to
        // verify every prefix length signals .needsMoreBytes and rewinds.
        // The previous behavior treated compressionFrameTruncated as
        // fatal, which killed the channel any time a server-side
        // compressed Data packet split across two TCP reads.
        var inner = ByteBuffer()
        inner.writeBytes(Array(repeating: UInt8(0x42), count: 1024))
        let frame = try ClickHouseCompressionFrame.encode(data: inner, method: .lz4)
        let allBytes = frame.getBytes(at: frame.readerIndex, length: frame.readableBytes) ?? []
        #expect(allBytes.count > 25, "frame must be larger than the header for the test to be meaningful")

        for prefixLength in 1..<allBytes.count {
            var buffer = ByteBuffer()
            buffer.writeBytes(Array(allBytes[0..<prefixLength]))
            let savedIndex = buffer.readerIndex

            let result = try ClickHouseFraming.tryFrame(from: &buffer) { buf in
                try ClickHouseCompressionFrame.decode(from: &buf)
            }
            guard case .needsMoreBytes = result else {
                Issue.record("prefix \(prefixLength) expected .needsMoreBytes")
                continue
            }
            #expect(buffer.readerIndex == savedIndex, "prefix \(prefixLength) did not rewind reader")
        }

        // Append the rest, frame must now succeed.
        var buffer = ByteBuffer()
        buffer.writeBytes(allBytes)
        let complete = try ClickHouseFraming.tryFrame(from: &buffer) { buf in
            try ClickHouseCompressionFrame.decode(from: &buf)
        }
        guard case .complete = complete else {
            Issue.record("complete frame failed to decode")
            return
        }
        #expect(buffer.readableBytes == 0)
    }

    @Test("two complete frames in succession advance the reader independently")
    func twoFramesInSuccession() throws {
        var buffer = ByteBuffer()
        ClickHouseServerPacketType.pong.write(into: &buffer)
        ClickHouseServerPacketType.endOfStream.write(into: &buffer)

        let r1 = try ClickHouseFraming.tryFrame(from: &buffer) { buf in
            try ClickHouseServerPacketReader.read(from: &buf, revision: 54_478)
        }
        let r2 = try ClickHouseFraming.tryFrame(from: &buffer) { buf in
            try ClickHouseServerPacketReader.read(from: &buf, revision: 54_478)
        }
        switch (r1, r2) {
        case (.complete(.pong), .complete(.endOfStream)):
            break
        default:
            Issue.record("packets out of order: \(r1), \(r2)")
        }
        #expect(buffer.readableBytes == 0)
    }

}
