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

@Suite("RESP batch writer")
struct RESPBatchWriterTests {

    private func parseAll(_ buffer: ByteBuffer) throws -> [RESPValue] {
        try RedisInboundHandler.parseFrames(in: buffer, depthLimit: 64, maxBulkBytes: 1 << 20).values
    }

    private func bulk(_ text: String) -> RESPValue {
        .bulkString(ByteBuffer(string: text))
    }

    @Test("a SET batch encodes one array command per pair")
    func setBatch() throws {
        let pairs = [RedisKeyValuePair(key: "a", value: "1"), RedisKeyValuePair(key: "bb", value: "22")]
        let frames = try parseAll(RESPBatchWriter.encodeSetBatch(pairs, allocator: ByteBufferAllocator()))
        #expect(frames == [
            .array([bulk("SET"), bulk("a"), bulk("1")]),
            .array([bulk("SET"), bulk("bb"), bulk("22")]),
        ])
    }

    @Test("a GET batch encodes one array command per key")
    func getBatch() throws {
        let frames = try parseAll(RESPBatchWriter.encodeGetBatch(["x", "yy"], allocator: ByteBufferAllocator()))
        #expect(frames == [
            .array([bulk("GET"), bulk("x")]),
            .array([bulk("GET"), bulk("yy")]),
        ])
    }

    @Test("an MSET batch encodes a single interleaved command")
    func multiSet() throws {
        let pairs = [RedisKeyValuePair(key: "a", value: "1"), RedisKeyValuePair(key: "b", value: "2")]
        let frames = try parseAll(RESPBatchWriter.encodeMultiSet(pairs, allocator: ByteBufferAllocator()))
        #expect(frames == [.array([bulk("MSET"), bulk("a"), bulk("1"), bulk("b"), bulk("2")])])
    }

    @Test("multi-digit lengths encode correctly")
    func multiDigitLengths() throws {
        let value = [UInt8](repeating: 0x7a, count: 1234)
        let frames = try parseAll(RESPBatchWriter.encodeSetBatch([RedisKeyValuePair(key: "k", value: value)], allocator: ByteBufferAllocator()))
        #expect(frames == [.array([bulk("SET"), bulk("k"), .bulkString(ByteBuffer(bytes: value))])])
    }

    @Test("binary-safe keys and values round-trip")
    func binarySafe() throws {
        let key: [UInt8] = [0x0d, 0x0a, 0x00]
        let value: [UInt8] = [0xff, 0x24, 0x2a]
        let frames = try parseAll(RESPBatchWriter.encodeSetBatch([RedisKeyValuePair(key: RedisKey(bytes: key), value: value)], allocator: ByteBufferAllocator()))
        #expect(frames == [.array([bulk("SET"), .bulkString(ByteBuffer(bytes: key)), .bulkString(ByteBuffer(bytes: value))])])
    }

    @Test("an empty value encodes a zero-length bulk string")
    func emptyValue() throws {
        let frames = try parseAll(RESPBatchWriter.encodeSetBatch([RedisKeyValuePair(key: "k", value: [])], allocator: ByteBufferAllocator()))
        #expect(frames == [.array([bulk("SET"), bulk("k"), .bulkString(ByteBuffer())])])
    }

    @Test("an arbitrary command pipeline encodes each command as a RESP array")
    func commandPipeline() throws {
        let commands = [RedisCommand("LRANGE", "k", "0", "-1"), RedisCommand("INCR", "c")]
        let frames = try parseAll(RESPBatchWriter.encodeCommands(commands, allocator: ByteBufferAllocator()))
        #expect(frames == [
            .array([bulk("LRANGE"), bulk("k"), bulk("0"), bulk("-1")]),
            .array([bulk("INCR"), bulk("c")]),
        ])
    }

    @Test("a command with a binary argument and multi-digit length round-trips")
    func commandBinaryArgument() throws {
        let argument = [UInt8](repeating: 0x00, count: 300) + [0x0d, 0x0a, 0xff]
        let command = RedisCommand(arguments: [Array("SET".utf8), Array("k".utf8), argument])
        let frames = try parseAll(RESPBatchWriter.encodeCommands([command], allocator: ByteBufferAllocator()))
        #expect(frames == [.array([bulk("SET"), bulk("k"), .bulkString(ByteBuffer(bytes: argument))])])
    }

    @Test("a single-argument command encodes as a one-element array")
    func singleArgumentCommand() throws {
        let frames = try parseAll(RESPBatchWriter.encodeCommands([RedisCommand("PING")], allocator: ByteBufferAllocator()))
        #expect(frames == [.array([bulk("PING")])])
    }
}
