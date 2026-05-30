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

// A decoded RESP array reply held as a single backing buffer plus a flat table
// of element descriptors, rather than an eager `[RESPValue]` tree. Decoding an
// N-element array records N `(offset, length)` descriptors into the receive
// buffer without allocating or reference-counting per element; the bytes for an
// element are sliced out only when that element is read. This single
// materialization (decode records offsets, the caller slices on demand) avoids
// the two-pass cost of building `[RESPValue]` and then converting it, which is
// what lets large array replies (range scans, geospatial results) match and
// beat a hand-written C client that allocates one reply node per element.
//
// The backing buffer is the receive-buffer region covering the whole reply,
// shared by reference count, so every element slice borrows it and the whole
// reply frees in one deallocation when the last reader releases it.
public final class RedisReplyArray: Sendable {

    enum Element: Sendable, Equatable {

        case bulkString(offset: Int, length: Int)
        case simpleString(offset: Int, length: Int)
        case integer(Int64)
        case null
        case serverError(prefix: String, message: String)
        case nested(RedisReplyArray)
    }

    let storage: ByteBuffer
    let elements: [Element]

    init(storage: ByteBuffer, elements: [Element]) {
        self.storage = storage
        self.elements = elements
    }

    public var count: Int {
        elements.count
    }

    public func bufferLookup(at index: Int) throws(RedisError) -> Lookup<ByteBuffer> {
        switch try element(at: index) {
        case .bulkString(let offset, let length): .found(try slice(at: offset, length: length))
        case .simpleString(let offset, let length): .found(try slice(at: offset, length: length))
        case .null: .notFound
        case .serverError(let prefix, let message): throw RedisError.serverError(prefix: prefix, message: message)
        default: throw RedisError.unexpectedResponseType(expected: "bulk string", actual: kind(at: index))
        }
    }

    public func bytesLookup(at index: Int) throws(RedisError) -> Lookup<[UInt8]> {
        switch try bufferLookup(at: index) {
        case .found(let buffer): .found(Array(buffer.readableBytesView))
        case .notFound: .notFound
        }
    }

    public func stringLookup(at index: Int) throws(RedisError) -> Lookup<String> {
        switch try bufferLookup(at: index) {
        case .found(let buffer): .found(try decodeUTF8(buffer))
        case .notFound: .notFound
        }
    }

    public func integerValue(at index: Int) throws(RedisError) -> Int64 {
        guard case .integer(let value) = try element(at: index) else {
            throw RedisError.unexpectedResponseType(expected: "integer", actual: kind(at: index))
        }
        return value
    }

    public func nestedArray(at index: Int) throws(RedisError) -> RedisReplyArray {
        guard case .nested(let array) = try element(at: index) else {
            throw RedisError.unexpectedResponseType(expected: "array", actual: kind(at: index))
        }
        return array
    }

    public func lookups() throws(RedisError) -> [Lookup<ByteBuffer>] {
        var result = [Lookup<ByteBuffer>]()
        result.reserveCapacity(elements.count)
        for index in elements.indices {
            result.append(try bufferLookup(at: index))
        }
        return result
    }

    public func value(at index: Int) throws(RedisError) -> RESPValue {
        switch try element(at: index) {
        case .bulkString(let offset, let length): .bulkString(try slice(at: offset, length: length))
        case .simpleString(let offset, let length): .simpleString(try slice(at: offset, length: length))
        case .integer(let value): .integer(value)
        case .null: .null
        case .serverError(let prefix, let message): .error(prefix: prefix, message: message)
        case .nested(let array): .array(try array.materialized())
        }
    }

    func materialized() throws(RedisError) -> [RESPValue] {
        var result = [RESPValue]()
        result.reserveCapacity(elements.count)
        for index in elements.indices {
            result.append(try value(at: index))
        }
        return result
    }

    func element(at index: Int) throws(RedisError) -> Element {
        guard elements.indices.contains(index) else {
            throw RedisError.protocolError(reason: "reply element index \(index) out of range \(elements.count)")
        }
        return elements[index]
    }

    private func slice(at offset: Int, length: Int) throws(RedisError) -> ByteBuffer {
        guard let payload = storage.getSlice(at: storage.readerIndex + offset, length: length) else {
            throw RedisError.protocolError(reason: "reply element slice out of bounds")
        }
        return payload
    }

    private func decodeUTF8(_ buffer: ByteBuffer) throws(RedisError) -> String {
        guard let text = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) else {
            throw RedisError.utf8DecodingFailed
        }
        return text
    }

    private func kind(at index: Int) -> String {
        guard elements.indices.contains(index) else { return "out-of-range" }
        switch elements[index] {
        case .bulkString: return "bulk string"
        case .simpleString: return "simple string"
        case .integer: return "integer"
        case .null: return "null"
        case .serverError: return "error"
        case .nested: return "array"
        }
    }
}

extension RedisReplyArray: Equatable {

    public static func == (lhs: RedisReplyArray, rhs: RedisReplyArray) -> Bool {
        guard lhs.elements.count == rhs.elements.count else { return false }
        for index in lhs.elements.indices where !elementsEqual(lhs, rhs, at: index) {
            return false
        }
        return true
    }

    private static func elementsEqual(_ lhs: RedisReplyArray, _ rhs: RedisReplyArray, at index: Int) -> Bool {
        switch (lhs.elements[index], rhs.elements[index]) {
        case (.integer(let a), .integer(let b)): return a == b
        case (.null, .null): return true
        case (.serverError(let pa, let ma), .serverError(let pb, let mb)): return pa == pb && ma == mb
        case (.nested(let a), .nested(let b)): return a == b
        default: return bytesEqual(lhs, rhs, at: index)
        }
    }

    private static func bytesEqual(_ lhs: RedisReplyArray, _ rhs: RedisReplyArray, at index: Int) -> Bool {
        do {
            return try lhs.bufferLookup(at: index) == rhs.bufferLookup(at: index)
        } catch {
            return false
        }
    }
}

extension RedisReplyArray: Hashable {

    public func hash(into hasher: inout Hasher) {
        hasher.combine(elements.count)
    }
}
