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

extension RESPValue {

    public var isNull: Bool {
        switch self {
        case .null: true
        default: false
        }
    }

    var kindName: String {
        switch self {
        case .simpleString: "simpleString"
        case .bulkString: "bulkString"
        case .integer: "integer"
        case .array: "array"
        case .arrayReply: "arrayReply"
        case .null: "null"
        case .error: "error"
        }
    }

    public func bufferValue() throws(RedisError) -> ByteBuffer {
        switch self {
        case .bulkString(let buffer): buffer
        case .simpleString(let buffer): buffer
        case .error(let prefix, let message): throw RedisError.serverError(prefix: prefix, message: message)
        case .integer, .array, .arrayReply, .null: throw RedisError.unexpectedResponseType(expected: "string", actual: kindName)
        }
    }

    public func bytesValue() throws(RedisError) -> [UInt8] {
        Array(try bufferValue().readableBytesView)
    }

    public func stringValue() throws(RedisError) -> String {
        try Self.decodeUTF8(bufferValue())
    }

    public func integerValue() throws(RedisError) -> Int64 {
        switch self {
        case .integer(let value): value
        case .error(let prefix, let message): throw RedisError.serverError(prefix: prefix, message: message)
        case .simpleString, .bulkString, .array, .arrayReply, .null: throw RedisError.unexpectedResponseType(expected: "integer", actual: kindName)
        }
    }

    public func arrayValue() throws(RedisError) -> [RESPValue] {
        switch self {
        case .array(let elements): elements
        case .arrayReply(let reply): try reply.materialized()
        case .error(let prefix, let message): throw RedisError.serverError(prefix: prefix, message: message)
        case .simpleString, .bulkString, .integer, .null: throw RedisError.unexpectedResponseType(expected: "array", actual: kindName)
        }
    }

    public func bufferLookup() throws(RedisError) -> Lookup<ByteBuffer> {
        switch self {
        case .null: Lookup.notFound
        case .bulkString(let buffer): Lookup.found(buffer)
        case .simpleString(let buffer): Lookup.found(buffer)
        case .error(let prefix, let message): throw RedisError.serverError(prefix: prefix, message: message)
        case .integer, .array, .arrayReply: throw RedisError.unexpectedResponseType(expected: "string-or-null", actual: kindName)
        }
    }

    public func bytesLookup() throws(RedisError) -> Lookup<[UInt8]> {
        switch try bufferLookup() {
        case .notFound: Lookup.notFound
        case .found(let buffer): Lookup.found(Array(buffer.readableBytesView))
        }
    }

    public func stringLookup() throws(RedisError) -> Lookup<String> {
        switch try bufferLookup() {
        case .notFound: Lookup.notFound
        case .found(let buffer): Lookup.found(try Self.decodeUTF8(buffer))
        }
    }

    static func decodeUTF8(_ buffer: ByteBuffer) throws(RedisError) -> String {
        guard let string = String(validating: buffer.readableBytesView, as: UTF8.self) else {
            throw RedisError.utf8DecodingFailed
        }
        return string
    }

    func throwingServerError() throws(RedisError) -> RESPValue {
        switch self {
        case .error(let prefix, let message): throw RedisError.serverError(prefix: prefix, message: message)
        default: self
        }
    }
}
