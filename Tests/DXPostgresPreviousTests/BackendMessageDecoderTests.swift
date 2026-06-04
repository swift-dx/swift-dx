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

import NIOCore
import Testing

@testable import DXPostgresPrevious

@Suite struct BackendMessageDecoderTests {

    private func frame(tag: UInt8, body: [UInt8]) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: body.count + 5)
        buffer.writeInteger(tag)
        buffer.writeInteger(Int32(body.count + 4))
        buffer.writeBytes(body)
        return buffer
    }

    private func decodeSingle(_ buffer: ByteBuffer) throws -> BackendMessage {
        guard case .message(let message, let consumed) = try BackendMessageDecoder.decodeOne(from: buffer) else {
            Issue.record("expected a complete message")
            throw PostgresError.protocolError(reason: "no message")
        }
        #expect(consumed == buffer.readableBytes)
        return message
    }

    @Test func decodesReadyForQuery() throws {
        let message = try decodeSingle(frame(tag: 0x5a, body: [0x49]))
        #expect(message == .readyForQuery(transactionStatus: 0x49))
    }

    @Test func decodesCommandComplete() throws {
        let message = try decodeSingle(frame(tag: 0x43, body: Array("INSERT 0 3\u{0}".utf8)))
        #expect(message == .commandComplete(tag: "INSERT 0 3"))
    }

    @Test func decodesBackendKeyData() throws {
        var body = ByteBufferAllocator().buffer(capacity: 8)
        body.writeInteger(Int32(4242))
        body.writeInteger(Int32(99))
        let message = try decodeSingle(frame(tag: 0x4b, body: Array(body.readableBytesView)))
        #expect(message == .backendKeyData(processID: 4242, secretKey: 99))
    }

    @Test func decodesErrorResponseIntoStructuredFields() throws {
        var body: [UInt8] = []
        body += Array("SERROR\u{0}".utf8)
        body += Array("C28P01\u{0}".utf8)
        body += Array("Mpassword authentication failed\u{0}".utf8)
        body += Array("Hcheck the role password\u{0}".utf8)
        body.append(0)
        let message = try decodeSingle(frame(tag: 0x45, body: body))
        guard case .error(let serverError) = message else {
            Issue.record("expected an error message")
            return
        }
        #expect(serverError.severity == "ERROR")
        #expect(serverError.sqlState == "28P01")
        #expect(serverError.message == "password authentication failed")
        #expect(serverError.value(of: .hint) == .present("check the role password"))
        #expect(serverError.value(of: .detail) == .absent)
    }

    @Test func decodesAuthenticationSASLMechanisms() throws {
        var body: [UInt8] = []
        body += [0, 0, 0, 10]
        body += Array("SCRAM-SHA-256\u{0}".utf8)
        body.append(0)
        let message = try decodeSingle(frame(tag: 0x52, body: body))
        #expect(message == .authentication(.saslMechanisms(["SCRAM-SHA-256"])))
    }

    @Test func decodesAuthenticationOk() throws {
        let message = try decodeSingle(frame(tag: 0x52, body: [0, 0, 0, 0]))
        #expect(message == .authentication(.ok))
    }

    @Test func decodesRowDescriptionAndDataRowWithNull() throws {
        var description = ByteBufferAllocator().buffer(capacity: 64)
        description.writeInteger(Int16(1))
        description.writeBytes(Array("id\u{0}".utf8))
        description.writeInteger(Int32(0))
        description.writeInteger(Int16(0))
        description.writeInteger(UInt32(23))
        description.writeInteger(Int16(4))
        description.writeInteger(Int32(-1))
        description.writeInteger(Int16(0))
        let descriptionMessage = try decodeSingle(frame(tag: 0x54, body: Array(description.readableBytesView)))
        #expect(descriptionMessage == .rowDescription([FieldDescription(name: "id", tableObjectID: 0, columnAttributeNumber: 0, dataTypeObjectID: 23, dataTypeSize: 4, typeModifier: -1, format: .text)]))

        var dataRow = ByteBufferAllocator().buffer(capacity: 32)
        dataRow.writeInteger(Int16(2))
        dataRow.writeInteger(Int32(2))
        dataRow.writeBytes(Array("42".utf8))
        dataRow.writeInteger(Int32(-1))
        let dataRowMessage = try decodeSingle(frame(tag: 0x44, body: Array(dataRow.readableBytesView)))
        #expect(dataRowMessage == .dataRow([.bytes(Array("42".utf8)), .sqlNull]))
    }

    @Test func reportsNeedMoreForPartialFrame() throws {
        var buffer = ByteBufferAllocator().buffer(capacity: 4)
        buffer.writeInteger(UInt8(0x5a))
        buffer.writeInteger(Int16(0))
        #expect(try BackendMessageDecoder.decodeOne(from: buffer) == .needMore)
    }

    @Test func rejectsUnknownMessageTag() {
        let buffer = frame(tag: 0x7a, body: [])
        #expect(throws: PostgresError.self) {
            try BackendMessageDecoder.decodeOne(from: buffer)
        }
    }
}
