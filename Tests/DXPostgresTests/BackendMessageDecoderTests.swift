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

import Testing
import NIOCore
@testable import DXPostgres

@Suite struct BackendMessageDecoderTests {

    @Test func decodesNotificationResponse() throws {
        let body = bigEndianInt32(4711) + cString("orders") + cString("{\"id\":7}")
        let buffer = bufferOf(message(0x41, body))
        guard case .message(let decoded, let consumed) = try BackendMessageDecoder.decodeOne(from: buffer) else {
            Issue.record("expected a decoded message")
            return
        }
        #expect(consumed == body.count + 5)
        guard case .notification(let processID, let channel, let payload) = decoded else {
            Issue.record("expected a notification, got \(decoded)")
            return
        }
        #expect(processID == 4711)
        #expect(channel == "orders")
        #expect(payload == "{\"id\":7}")
    }

    @Test func decodesDataRowDistinguishingNullFromEmpty() throws {
        let body = bigEndianInt16(3)
            + bigEndianInt32(3) + Array("abc".utf8)
            + bigEndianInt32(-1)
            + bigEndianInt32(0)
        let buffer = bufferOf(message(0x44, body))
        guard case .message(let decoded, _) = try BackendMessageDecoder.decodeOne(from: buffer) else {
            Issue.record("expected a decoded message")
            return
        }
        guard case .dataRow(let cells) = decoded else {
            Issue.record("expected a data row, got \(decoded)")
            return
        }
        #expect(cells == [.bytes(Array("abc".utf8)), .sqlNull, .bytes([])])
    }

    @Test func reportsNeedMoreForPartialFrame() throws {
        let full = message(0x41, bigEndianInt32(1) + cString("c") + cString("p"))
        let buffer = bufferOf(Array(full.prefix(full.count - 2)))
        #expect(try BackendMessageDecoder.decodeOne(from: buffer) == .needMore)
    }

    @Test func decodesEmptyChannelAndPayload() throws {
        let body = bigEndianInt32(1) + cString("") + cString("")
        let buffer = bufferOf(message(0x41, body))
        guard case .message(.notification(let processID, let channel, let payload), _) = try BackendMessageDecoder.decodeOne(from: buffer) else {
            Issue.record("expected a notification")
            return
        }
        #expect(processID == 1)
        #expect(channel == "")
        #expect(payload == "")
    }

    @Test func rejectsMessageLengthBelowMinimum() throws {
        let buffer = bufferOf([0x5A, 0x00, 0x00, 0x00, 0x03])
        #expect(throws: PostgresError.self) {
            _ = try BackendMessageDecoder.decodeOne(from: buffer)
        }
    }

    @Test func rejectsUnknownMessageTag() throws {
        let buffer = bufferOf(message(0xFF, []))
        #expect(throws: PostgresError.self) {
            _ = try BackendMessageDecoder.decodeOne(from: buffer)
        }
    }

    @Test func rejectsUnterminatedCString() throws {
        let buffer = bufferOf(message(0x43, Array("SELECT 1".utf8)))
        #expect(throws: PostgresError.self) {
            _ = try BackendMessageDecoder.decodeOne(from: buffer)
        }
    }

    @Test func rejectsTruncatedDataRowColumn() throws {
        let body = bigEndianInt16(1) + bigEndianInt32(10) + Array("ab".utf8)
        let buffer = bufferOf(message(0x44, body))
        #expect(throws: PostgresError.self) {
            _ = try BackendMessageDecoder.decodeOne(from: buffer)
        }
    }

    @Test func decodesRowDescriptionFieldsWithFormats() throws {
        let body = bigEndianInt16(2)
            + describeField(name: "id", typeObjectID: 23, formatCode: 0)
            + describeField(name: "amount", typeObjectID: 1700, formatCode: 1)
        let buffer = bufferOf(message(0x54, body))
        guard case .message(.rowDescription(let fields), _) = try BackendMessageDecoder.decodeOne(from: buffer) else {
            Issue.record("expected a row description")
            return
        }
        #expect(fields.count == 2)
        #expect(fields[0].name == "id")
        #expect(fields[0].dataTypeObjectID == 23)
        #expect(fields[0].format == .text)
        #expect(fields[1].name == "amount")
        #expect(fields[1].dataTypeObjectID == 1700)
        #expect(fields[1].format == .binary)
    }

    @Test func rejectsRowDescriptionWithUnknownFormatCode() throws {
        let body = bigEndianInt16(1) + describeField(name: "id", typeObjectID: 23, formatCode: 2)
        let buffer = bufferOf(message(0x54, body))
        #expect(throws: PostgresError.self) {
            _ = try BackendMessageDecoder.decodeOne(from: buffer)
        }
    }

    private func describeField(name: String, typeObjectID: Int32, formatCode: Int16) -> [UInt8] {
        cString(name)
            + bigEndianInt32(0)
            + bigEndianInt16(0)
            + bigEndianInt32(typeObjectID)
            + bigEndianInt16(4)
            + bigEndianInt32(-1)
            + bigEndianInt16(formatCode)
    }

    private func bufferOf(_ bytes: [UInt8]) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        return buffer
    }

    private func message(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
        [tag] + bigEndianInt32(Int32(body.count + 4)) + body
    }

    private func cString(_ value: String) -> [UInt8] {
        Array(value.utf8) + [0]
    }

    private func bigEndianInt16(_ value: Int16) -> [UInt8] {
        let bits = UInt16(bitPattern: value)
        return [UInt8(bits >> 8 & 0xFF), UInt8(bits & 0xFF)]
    }

    private func bigEndianInt32(_ value: Int32) -> [UInt8] {
        let bits = UInt32(bitPattern: value)
        return [UInt8(bits >> 24 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits & 0xFF)]
    }
}
