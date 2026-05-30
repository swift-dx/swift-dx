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

@Suite("RESP parser")
struct RESPParserTests {

    private func parse(_ text: String, depthLimit: Int = 64, maxBulkBytes: Int = 536_870_912) throws -> RESPParser.Outcome {
        try parse(Array(text.utf8), depthLimit: depthLimit, maxBulkBytes: maxBulkBytes)
    }

    private func parse(_ bytes: [UInt8], depthLimit: Int = 64, maxBulkBytes: Int = 536_870_912) throws -> RESPParser.Outcome {
        var buffer = ByteBuffer()
        buffer.writeBytes(bytes)
        return try RESPParser(buffer: buffer, depthLimit: depthLimit, maxBulkBytes: maxBulkBytes).parse(from: buffer.readerIndex)
    }

    @Test("simple string parses with byte count")
    func simpleString() throws {
        #expect(try parse("+OK\r\n") == .complete(.simpleString(ByteBuffer(string: "OK")), bytesConsumed: 5))
    }

    @Test("error reply splits prefix and message")
    func errorWithMessage() throws {
        #expect(try parse("-WRONGTYPE bad op\r\n") == .complete(.error(prefix: "WRONGTYPE", message: "bad op"), bytesConsumed: 19))
    }

    @Test("error reply with only a prefix has empty message")
    func errorPrefixOnly() throws {
        #expect(try parse("-ERR\r\n") == .complete(.error(prefix: "ERR", message: ""), bytesConsumed: 6))
    }

    @Test("positive and negative integers parse")
    func integers() throws {
        #expect(try parse(":1000\r\n") == .complete(.integer(1000), bytesConsumed: 7))
        #expect(try parse(":-5\r\n") == .complete(.integer(-5), bytesConsumed: 5))
    }

    @Test("bulk string parses exact payload length")
    func bulkString() throws {
        #expect(try parse("$5\r\nhello\r\n") == .complete(.bulkString(ByteBuffer(string: "hello")), bytesConsumed: 11))
    }

    @Test("empty bulk string parses to empty bytes")
    func emptyBulk() throws {
        #expect(try parse("$0\r\n\r\n") == .complete(.bulkString(ByteBuffer()), bytesConsumed: 6))
    }

    @Test("null bulk string parses to null")
    func nullBulk() throws {
        #expect(try parse("$-1\r\n") == .complete(.null, bytesConsumed: 5))
    }

    @Test("bulk payload containing CRLF is binary-safe")
    func binarySafeBulk() throws {
        let bytes = Array("$2\r\n".utf8) + [0x0d, 0x0a] + Array("\r\n".utf8)
        #expect(try parse(bytes) == .complete(.bulkString(ByteBuffer(bytes: [0x0d, 0x0a])), bytesConsumed: 8))
    }

    @Test("array of integers parses")
    func arrayOfIntegers() throws {
        #expect(try parse("*2\r\n:1\r\n:2\r\n") == .complete(.array([.integer(1), .integer(2)]), bytesConsumed: 12))
    }

    @Test("empty array parses")
    func emptyArray() throws {
        #expect(try parse("*0\r\n") == .complete(.array([]), bytesConsumed: 4))
    }

    @Test("null array parses to null")
    func nullArray() throws {
        #expect(try parse("*-1\r\n") == .complete(.null, bytesConsumed: 5))
    }

    @Test("nested array parses recursively")
    func nestedArray() throws {
        #expect(try parse("*1\r\n*1\r\n:7\r\n") == .complete(.array([.array([.integer(7)])]), bytesConsumed: 12))
    }

    @Test("mixed array of bulk and null parses")
    func mixedArray() throws {
        let expected = RESPValue.array([.bulkString(ByteBuffer(string: "a")), .null])
        #expect(try parse("*2\r\n$1\r\na\r\n$-1\r\n") == .complete(expected, bytesConsumed: 16))
    }

    @Test("incomplete type line needs more bytes")
    func incompleteLine() throws {
        #expect(try parse("+OK") == .needMore)
    }

    @Test("incomplete bulk payload needs more bytes")
    func incompleteBulk() throws {
        #expect(try parse("$5\r\nhel") == .needMore)
    }

    @Test("incomplete array element needs more bytes")
    func incompleteArray() throws {
        #expect(try parse("*2\r\n:1\r\n") == .needMore)
    }

    @Test("bulk length line without terminator needs more bytes")
    func incompleteBulkHeader() throws {
        #expect(try parse("$5\r") == .needMore)
    }

    @Test("only the first frame is consumed when two are buffered")
    func firstOfTwoFrames() throws {
        #expect(try parse("+OK\r\n:9\r\n") == .complete(.simpleString(ByteBuffer(string: "OK")), bytesConsumed: 5))
    }

    @Test("array nesting beyond the depth limit throws")
    func depthLimit() {
        #expect(throws: RedisError.responseDepthLimitExceeded(limit: 2)) {
            try parse("*1\r\n*1\r\n*1\r\n:1\r\n", depthLimit: 2)
        }
    }

    @Test("bulk length beyond the configured maximum throws")
    func bulkTooLarge() {
        #expect(throws: RedisError.malformedLength(reason: "bulk length 10 exceeds limit 4")) {
            try parse("$10\r\n0123456789\r\n", maxBulkBytes: 4)
        }
    }

    @Test("unknown type byte throws a protocol error")
    func unknownTypeByte() {
        #expect(throws: RedisError.self) {
            try parse("%1\r\n")
        }
    }

    @Test("non-numeric integer payload throws")
    func malformedInteger() {
        #expect(throws: RedisError.self) {
            try parse(":abc\r\n")
        }
    }

    @Test("an integer exceeding Int64 throws rather than overflowing")
    func integerOverflowThrows() {
        #expect(throws: RedisError.self) {
            try parse(":99999999999999999999999\r\n")
        }
    }

    @Test("a negative integer reply parses")
    func negativeInteger() throws {
        #expect(try parse(":-9223372036854775807\r\n") == .complete(.integer(-9223372036854775807), bytesConsumed: 23))
    }

    @Test("a carriage return not followed by a line feed throws rather than truncating")
    func loneCarriageReturnThrows() {
        #expect(throws: RedisError.protocolError(reason: "RESP line CR not followed by LF")) {
            try parse("+OK\rX\r\n")
        }
    }

    @Test("a line ending in a bare carriage return at the buffer edge needs more bytes")
    func trailingCarriageReturnNeedsMore() throws {
        #expect(try parse("+OK\r") == .needMore)
    }

    @Test("a bulk payload not terminated by CRLF throws")
    func bulkBadTerminatorThrows() {
        #expect(throws: RedisError.protocolError(reason: "bulk payload not terminated by CRLF")) {
            try parse("$2\r\nABxy")
        }
    }

    @Test("a bulk payload missing its trailing line feed needs more bytes")
    func bulkPartialTerminatorNeedsMore() throws {
        #expect(try parse("$2\r\nAB\r") == .needMore)
    }
}
