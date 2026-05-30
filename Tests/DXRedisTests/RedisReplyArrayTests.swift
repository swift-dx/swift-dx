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
import DXCore
import NIOCore
import Testing

@Suite("Redis reply array")
struct RedisReplyArrayTests {

    private func decode(_ text: String) throws -> RedisReplyArray {
        var buffer = ByteBuffer()
        buffer.writeBytes(Array(text.utf8))
        let parser = RESPParser(buffer: buffer, depthLimit: 64, maxBulkBytes: 1 << 20)
        guard case .complete(let array, _) = try parser.parseReplyArray(from: buffer.readerIndex) else {
            Issue.record("expected a complete array")
            return RedisReplyArray(storage: ByteBuffer(), elements: [])
        }
        return array
    }

    @Test("a flat bulk array decodes count and per-index lookups")
    func flatBulkArray() throws {
        let array = try decode("*3\r\n$5\r\nhello\r\n$5\r\nworld\r\n$-1\r\n")
        #expect(array.count == 3)
        #expect(try array.bufferLookup(at: 0) == Lookup.found(ByteBuffer(string: "hello")))
        #expect(try array.stringLookup(at: 1) == Lookup.found("world"))
        #expect(try array.bytesLookup(at: 2) == Lookup<[UInt8]>.notFound)
    }

    @Test("lookups materializes every element in one pass")
    func lookupsAll() throws {
        let array = try decode("*2\r\n$1\r\na\r\n$1\r\nb\r\n")
        #expect(try array.lookups() == [Lookup.found(ByteBuffer(string: "a")), Lookup.found(ByteBuffer(string: "b"))])
    }

    @Test("integer elements read back through integerValue")
    func integerElements() throws {
        let array = try decode("*2\r\n:7\r\n:-3\r\n")
        #expect(try array.integerValue(at: 0) == 7)
        #expect(try array.integerValue(at: 1) == -3)
    }

    @Test("a nested array is exposed as a child reply array")
    func nestedArray() throws {
        let array = try decode("*1\r\n*2\r\n$1\r\nx\r\n:5\r\n")
        let child = try array.nestedArray(at: 0)
        #expect(child.count == 2)
        #expect(try child.stringLookup(at: 0) == Lookup.found("x"))
        #expect(try child.integerValue(at: 1) == 5)
    }

    @Test("an empty array decodes to zero elements")
    func emptyArray() throws {
        #expect(try decode("*0\r\n").count == 0)
    }

    @Test("reading a bulk index as an integer throws")
    func wrongTypeThrows() throws {
        let array = try decode("*1\r\n$1\r\na\r\n")
        #expect(throws: RedisError.self) {
            try array.integerValue(at: 0)
        }
    }

    @Test("an out-of-range index throws")
    func indexOutOfRange() throws {
        let array = try decode("*1\r\n:1\r\n")
        #expect(throws: RedisError.self) {
            try array.bufferLookup(at: 5)
        }
    }

    @Test("value reads an element back as a RESPValue")
    func valueAccessor() throws {
        let array = try decode("*2\r\n$1\r\na\r\n:9\r\n")
        #expect(try array.value(at: 0) == .bulkString(ByteBuffer(string: "a")))
        #expect(try array.value(at: 1) == .integer(9))
    }

    @Test("an incomplete array reports needMore without consuming")
    func incompleteNeedsMore() throws {
        var buffer = ByteBuffer()
        buffer.writeBytes(Array("*2\r\n$1\r\na\r\n".utf8))
        let parser = RESPParser(buffer: buffer, depthLimit: 64, maxBulkBytes: 1 << 20)
        #expect(try parser.parseReplyArray(from: buffer.readerIndex) == .needMore)
    }

    @Test("arrayValue on a wrapped reply array materializes the elements")
    func wrappedArrayValueMaterializes() throws {
        let array = try decode("*2\r\n$1\r\na\r\n$1\r\nb\r\n")
        let wrapped = RESPValue.arrayReply(array)
        #expect(try wrapped.arrayValue() == [.bulkString(ByteBuffer(string: "a")), .bulkString(ByteBuffer(string: "b"))])
    }

    @Test("the resumable element reader parses a whole array in one pass")
    func resumableSinglePass() throws {
        var buffer = ByteBuffer()
        buffer.writeBytes(Array("*3\r\n$1\r\na\r\n$1\r\nb\r\n$1\r\nc\r\n".utf8))
        let parser = RESPParser(buffer: buffer, depthLimit: 64, maxBulkBytes: 1 << 20)
        guard case .header(let count, let elementsStart) = try parser.beginReplyArray(from: buffer.readerIndex) else {
            Issue.record("expected an array header")
            return
        }
        var remaining = count
        var elements = [RedisReplyArray.Element]()
        var cursor = elementsStart
        #expect(try parser.resumeReplyArrayElements(remaining: &remaining, elements: &elements, cursor: &cursor, base: buffer.readerIndex))
        let array = RedisReplyArray(storage: try parser.sliceFrame(from: buffer.readerIndex, to: cursor), elements: elements)
        #expect(try array.lookups() == [Lookup.found(ByteBuffer(string: "a")), Lookup.found(ByteBuffer(string: "b")), Lookup.found(ByteBuffer(string: "c"))])
    }

    @Test("the resumable element reader continues across reads without rescanning")
    func resumableAcrossReads() throws {
        var first = ByteBuffer()
        first.writeBytes(Array("*3\r\n$1\r\na\r\n$1\r".utf8))
        let parserA = RESPParser(buffer: first, depthLimit: 64, maxBulkBytes: 1 << 20)
        guard case .header(let count, let elementsStart) = try parserA.beginReplyArray(from: first.readerIndex) else {
            Issue.record("expected an array header")
            return
        }
        var remaining = count
        var elements = [RedisReplyArray.Element]()
        var cursor = elementsStart
        #expect(!(try parserA.resumeReplyArrayElements(remaining: &remaining, elements: &elements, cursor: &cursor, base: first.readerIndex)))
        #expect(remaining == 2)
        #expect(elements.count == 1)
        let cursorAfterFirstRead = cursor

        var second = first
        second.writeBytes(Array("\nb\r\n$1\r\nc\r\n".utf8))
        let parserB = RESPParser(buffer: second, depthLimit: 64, maxBulkBytes: 1 << 20)
        #expect(cursor == cursorAfterFirstRead)
        #expect(try parserB.resumeReplyArrayElements(remaining: &remaining, elements: &elements, cursor: &cursor, base: second.readerIndex))
        let array = RedisReplyArray(storage: try parserB.sliceFrame(from: second.readerIndex, to: cursor), elements: elements)
        #expect(try array.lookups() == [Lookup.found(ByteBuffer(string: "a")), Lookup.found(ByteBuffer(string: "b")), Lookup.found(ByteBuffer(string: "c"))])
    }

    @Test("the array-frame decoder wraps array replies and passes through errors")
    func arrayFrameDecoder() throws {
        var buffer = ByteBuffer()
        buffer.writeBytes(Array("*1\r\n$1\r\na\r\n-WRONGTYPE bad\r\n".utf8))
        let result = try RedisInboundHandler.parseArrayFrames(in: buffer, depthLimit: 64, maxBulkBytes: 1 << 20)
        #expect(result.values.count == 2)
        guard case .arrayReply(let array) = result.values[0] else {
            Issue.record("expected an array reply")
            return
        }
        #expect(array.count == 1)
        #expect(result.values[1] == .error(prefix: "WRONGTYPE", message: "bad"))
    }
}
