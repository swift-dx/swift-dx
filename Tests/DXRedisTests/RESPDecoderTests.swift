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

@testable import DXRedis
import NIOCore
import Testing

@Suite("RESP frame batching")
struct RESPDecoderTests {

    private func parseFrames(_ text: String) throws -> (Int, [RESPValue]) {
        var buffer = ByteBuffer()
        buffer.writeBytes(Array(text.utf8))
        return try RedisInboundHandler.parseFrames(in: buffer, depthLimit: 64, maxBulkBytes: 1 << 20)
    }

    @Test("all complete frames in one buffer are parsed in a single pass")
    func multipleFrames() throws {
        let (consumed, values) = try parseFrames("+OK\r\n:42\r\n$3\r\nabc\r\n")
        #expect(consumed == 19)
        #expect(values == [.simpleString(ByteBuffer(string: "OK")), .integer(42), .bulkString(ByteBuffer(string: "abc"))])
    }

    @Test("an array frame is parsed whole")
    func arrayFrame() throws {
        let (consumed, values) = try parseFrames("*2\r\n:1\r\n:2\r\n")
        #expect(consumed == 12)
        #expect(values == [.array([.integer(1), .integer(2)])])
    }

    @Test("a trailing partial frame is left unconsumed for the next read")
    func partialTail() throws {
        let (consumed, values) = try parseFrames("+OK\r\n:4")
        #expect(consumed == 5)
        #expect(values == [.simpleString(ByteBuffer(string: "OK"))])
    }

    @Test("a buffer with no complete frame consumes nothing")
    func noCompleteFrame() throws {
        let (consumed, values) = try parseFrames("$5\r\nhel")
        #expect(consumed == 0)
        #expect(values.isEmpty)
    }

    @Test("an empty buffer yields no frames")
    func emptyBuffer() throws {
        let (consumed, values) = try parseFrames("")
        #expect(consumed == 0)
        #expect(values.isEmpty)
    }

    @Test("a complete frame followed by a partial frame parses only the complete one")
    func completeThenPartial() throws {
        let (consumed, values) = try parseFrames("$3\r\nabc\r\n$5\r\nhe")
        #expect(consumed == 9)
        #expect(values == [.bulkString(ByteBuffer(string: "abc"))])
    }
}
