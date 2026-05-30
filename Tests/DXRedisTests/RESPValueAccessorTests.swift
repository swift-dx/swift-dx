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
@testable import DXRedis
import NIOCore
import Testing

@Suite("RESPValue accessors")
struct RESPValueAccessorTests {

    @Test("isNull is true only for the null case")
    func isNull() {
        #expect(RESPValue.null.isNull)
        #expect(!RESPValue.integer(1).isNull)
    }

    @Test("bytesValue returns payloads for string replies")
    func bytesValue() throws {
        #expect(try RESPValue.bulkString(ByteBuffer(bytes: [1, 2])).bytesValue() == [1, 2])
        #expect(try RESPValue.simpleString(ByteBuffer(string: "OK")).bytesValue() == Array("OK".utf8))
    }

    @Test("bytesValue throws on a server error reply")
    func bytesValueErrorReply() {
        #expect(throws: RedisError.serverError(prefix: "ERR", message: "x")) {
            try RESPValue.error(prefix: "ERR", message: "x").bytesValue()
        }
    }

    @Test("bytesValue throws on a non-string reply")
    func bytesValueWrongType() {
        #expect(throws: RedisError.unexpectedResponseType(expected: "string", actual: "integer")) {
            try RESPValue.integer(1).bytesValue()
        }
    }

    @Test("integerValue returns the integer and rejects other shapes")
    func integerValue() throws {
        #expect(try RESPValue.integer(99).integerValue() == 99)
        #expect(throws: RedisError.self) {
            try RESPValue.null.integerValue()
        }
    }

    @Test("arrayValue returns elements and rejects other shapes")
    func arrayValue() throws {
        #expect(try RESPValue.array([.integer(1)]).arrayValue() == [.integer(1)])
        #expect(throws: RedisError.self) {
            try RESPValue.bulkString(ByteBuffer()).arrayValue()
        }
    }

    @Test("stringValue decodes UTF-8 and rejects invalid bytes")
    func stringValue() throws {
        #expect(try RESPValue.bulkString(ByteBuffer(string: "hi")).stringValue() == "hi")
        #expect(throws: RedisError.utf8DecodingFailed) {
            try RESPValue.bulkString(ByteBuffer(bytes: [0xff, 0xfe])).stringValue()
        }
    }

    @Test("bytesLookup maps null to notFound and bulk to found")
    func bytesLookup() throws {
        #expect(try RESPValue.null.bytesLookup() == Lookup.notFound)
        #expect(try RESPValue.bulkString(ByteBuffer(bytes: [7])).bytesLookup() == Lookup.found([7]))
    }

    @Test("stringLookup maps null to notFound and bulk to a decoded string")
    func stringLookup() throws {
        #expect(try RESPValue.null.stringLookup() == Lookup.notFound)
        #expect(try RESPValue.bulkString(ByteBuffer(string: "v")).stringLookup() == Lookup.found("v"))
    }

    @Test("throwingServerError rethrows errors and passes other values through")
    func throwingServerError() throws {
        #expect(try RESPValue.integer(3).throwingServerError() == .integer(3))
        #expect(throws: RedisError.serverError(prefix: "ERR", message: "no")) {
            try RESPValue.error(prefix: "ERR", message: "no").throwingServerError()
        }
    }
}
