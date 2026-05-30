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

import DXCore
import NIOCore

// Hot-path encoder for the SET / MSET / GET batches that carry the bulk of the
// throughput. It builds the entire batch into one ByteBuffer region obtained via
// writeWithUnsafeMutableBytes and writes every byte through a raw pointer: ASCII
// integers are emitted digit-by-digit into place and key/value payloads are
// copied with a single memcpy each. This avoids the per-field ByteBuffer call
// overhead (one bounds-checked call per '$', length, CRLF, and payload) that
// otherwise dominates a million-command pipeline. The reserved capacity is an
// upper bound; the closure returns the exact number of bytes written.
enum RESPBatchWriter {

    static let maxDecimalDigits = 20

    static func encodeSetBatch(_ pairs: [RedisKeyValuePair], allocator: ByteBufferAllocator) -> ByteBuffer {
        let header = Array("*3\r\n$3\r\nSET\r\n".utf8)
        let capacity = max(1, setCapacity(pairs, headerLength: header.count))
        var buffer = allocator.buffer(capacity: capacity)
        buffer.writeWithUnsafeMutableBytes(minimumWritableBytes: capacity) { rawPointer -> Int in
            guard let destination = rawPointer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return writeSetFrames(pairs, header: header, into: destination)
        }
        return buffer
    }

    // Encodes a pipeline of arbitrary commands (the path every custom command
    // takes: GEOSEARCH, ZRANGE, LRANGE, and any user-built query) through the same
    // raw-pointer writer the typed batches use, so custom-command reads encode as
    // fast as the built-in SET/GET batches rather than through per-field
    // ByteBuffer calls.
    static func encodeCommands(_ commands: [RedisCommand], allocator: ByteBufferAllocator) -> ByteBuffer {
        let capacity = max(1, commandsCapacity(commands))
        var buffer = allocator.buffer(capacity: capacity)
        buffer.writeWithUnsafeMutableBytes(minimumWritableBytes: capacity) { rawPointer -> Int in
            guard let destination = rawPointer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return writeCommands(commands, into: destination)
        }
        return buffer
    }

    private static func writeCommands(_ commands: [RedisCommand], into destination: UnsafeMutablePointer<UInt8>) -> Int {
        var offset = 0
        for command in commands {
            writeArrayHeader(into: destination, offset: &offset, count: command.arguments.count)
            for argument in command.arguments {
                writeBulk(into: destination, offset: &offset, bytes: argument)
            }
        }
        return offset
    }

    private static func commandsCapacity(_ commands: [RedisCommand]) -> Int {
        var total = 0
        for command in commands {
            total &+= 1 &+ maxDecimalDigits &+ 2 &+ argumentsCapacity(command.arguments)
        }
        return total
    }

    private static func argumentsCapacity(_ arguments: [[UInt8]]) -> Int {
        var total = 0
        for argument in arguments {
            total &+= bulkLength(argument.count)
        }
        return total
    }

    static func encodeMultiSet(_ pairs: [RedisKeyValuePair], allocator: ByteBufferAllocator) -> ByteBuffer {
        let verb = Array("MSET".utf8)
        let capacity = max(1, setCapacity(pairs, headerLength: 0) + maxDecimalDigits + 3 + bulkLength(verb.count))
        var buffer = allocator.buffer(capacity: capacity)
        buffer.writeWithUnsafeMutableBytes(minimumWritableBytes: capacity) { rawPointer -> Int in
            guard let destination = rawPointer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return writeMultiSetFrame(pairs, verb: verb, into: destination)
        }
        return buffer
    }

    static func encodeGetBatch(_ keys: [RedisKey], allocator: ByteBufferAllocator) -> ByteBuffer {
        let header = Array("*2\r\n$3\r\nGET\r\n".utf8)
        let capacity = max(1, getCapacity(keys, headerLength: header.count))
        var buffer = allocator.buffer(capacity: capacity)
        buffer.writeWithUnsafeMutableBytes(minimumWritableBytes: capacity) { rawPointer -> Int in
            guard let destination = rawPointer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return writeGetFrames(keys, header: header, into: destination)
        }
        return buffer
    }

    private static func writeSetFrames(_ pairs: [RedisKeyValuePair], header: [UInt8], into destination: UnsafeMutablePointer<UInt8>) -> Int {
        var offset = 0
        header.withUnsafeBufferPointer { headerPointer in
            guard let headerBase = headerPointer.baseAddress else { return }
            pairs.withUnsafeBufferPointer { pairsPointer in
                for index in 0..<pairsPointer.count {
                    writeSetFrame(into: destination, offset: &offset, headerBase: headerBase, headerLength: headerPointer.count, pair: pairsPointer[index])
                }
            }
        }
        return offset
    }

    @inline(__always)
    private static func writeSetFrame(into destination: UnsafeMutablePointer<UInt8>, offset: inout Int, headerBase: UnsafePointer<UInt8>, headerLength: Int, pair: RedisKeyValuePair) {
        destination.advanced(by: offset).update(from: headerBase, count: headerLength)
        offset &+= headerLength
        writeBulk(into: destination, offset: &offset, bytes: pair.key.bytes)
        writeBulk(into: destination, offset: &offset, bytes: pair.value)
    }

    private static func writeMultiSetFrame(_ pairs: [RedisKeyValuePair], verb: [UInt8], into destination: UnsafeMutablePointer<UInt8>) -> Int {
        var offset = 0
        writeArrayHeader(into: destination, offset: &offset, count: pairs.count * 2 + 1)
        writeBulk(into: destination, offset: &offset, bytes: verb)
        pairs.withUnsafeBufferPointer { pairsPointer in
            for index in 0..<pairsPointer.count {
                writeBulk(into: destination, offset: &offset, bytes: pairsPointer[index].key.bytes)
                writeBulk(into: destination, offset: &offset, bytes: pairsPointer[index].value)
            }
        }
        return offset
    }

    private static func writeGetFrames(_ keys: [RedisKey], header: [UInt8], into destination: UnsafeMutablePointer<UInt8>) -> Int {
        var offset = 0
        header.withUnsafeBufferPointer { headerPointer in
            guard let headerBase = headerPointer.baseAddress else { return }
            keys.withUnsafeBufferPointer { keysPointer in
                for index in 0..<keysPointer.count {
                    writeGetFrame(into: destination, offset: &offset, headerBase: headerBase, headerLength: headerPointer.count, key: keysPointer[index])
                }
            }
        }
        return offset
    }

    @inline(__always)
    private static func writeGetFrame(into destination: UnsafeMutablePointer<UInt8>, offset: inout Int, headerBase: UnsafePointer<UInt8>, headerLength: Int, key: RedisKey) {
        destination.advanced(by: offset).update(from: headerBase, count: headerLength)
        offset &+= headerLength
        writeBulk(into: destination, offset: &offset, bytes: key.bytes)
    }

    @inline(__always)
    private static func writeArrayHeader(into destination: UnsafeMutablePointer<UInt8>, offset: inout Int, count: Int) {
        destination[offset] = Ascii.asterisk
        offset &+= 1
        let value = UInt64(truncatingIfNeeded: count)
        writeDecimal(into: destination, offset: &offset, value: value, length: decimalLength(value))
        writeCarriageReturnLineFeed(into: destination, offset: &offset)
    }

    @inline(__always)
    private static func writeBulk(into destination: UnsafeMutablePointer<UInt8>, offset: inout Int, bytes: [UInt8]) {
        let length = bytes.count
        destination[offset] = Ascii.dollar
        offset &+= 1
        writeDecimal(into: destination, offset: &offset, value: UInt64(truncatingIfNeeded: length), length: decimalLength(UInt64(truncatingIfNeeded: length)))
        writeCarriageReturnLineFeed(into: destination, offset: &offset)
        copyBytes(into: destination, offset: &offset, bytes: bytes, count: length)
        writeCarriageReturnLineFeed(into: destination, offset: &offset)
    }

    @inline(__always)
    private static func copyBytes(into destination: UnsafeMutablePointer<UInt8>, offset: inout Int, bytes: [UInt8], count: Int) {
        guard count > 0 else { return }
        bytes.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            destination.advanced(by: offset).update(from: base, count: count)
        }
        offset &+= count
    }

    @inline(__always)
    private static func writeCarriageReturnLineFeed(into destination: UnsafeMutablePointer<UInt8>, offset: inout Int) {
        destination[offset] = Ascii.carriageReturn
        destination[offset &+ 1] = Ascii.lineFeed
        offset &+= 2
    }

    @inline(__always)
    private static func writeDecimal(into destination: UnsafeMutablePointer<UInt8>, offset: inout Int, value: UInt64, length: Int) {
        guard value != 0 else {
            destination[offset] = Ascii.digitZero
            offset &+= 1
            return
        }
        var remaining = value
        var position = offset &+ length &- 1
        while remaining > 0 {
            destination[position] = UInt8(truncatingIfNeeded: remaining % Radix.decimal) &+ Ascii.digitZero
            remaining /= Radix.decimal
            position &-= 1
        }
        offset &+= length
    }

    @inline(__always)
    private static func decimalLength(_ value: UInt64) -> Int {
        guard value != 0 else { return 1 }
        var remaining = value
        var length = 0
        while remaining > 0 {
            length &+= 1
            remaining /= Radix.decimal
        }
        return length
    }

    private static func setCapacity(_ pairs: [RedisKeyValuePair], headerLength: Int) -> Int {
        var total = 0
        for pair in pairs {
            total &+= headerLength &+ bulkLength(pair.key.bytes.count) &+ bulkLength(pair.value.count)
        }
        return total
    }

    private static func getCapacity(_ keys: [RedisKey], headerLength: Int) -> Int {
        var total = 0
        for key in keys {
            total &+= headerLength &+ bulkLength(key.bytes.count)
        }
        return total
    }

    @inline(__always)
    private static func bulkLength(_ payloadLength: Int) -> Int {
        1 &+ maxDecimalDigits &+ 2 &+ payloadLength &+ 2
    }
}
