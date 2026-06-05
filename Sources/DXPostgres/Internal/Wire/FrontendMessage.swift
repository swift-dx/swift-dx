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

// Serializers for the frontend (client-to-server) half of the PostgreSQL v3
// wire protocol. Each function returns a ByteBuffer holding exactly one complete
// message, ready to write to the channel. The StartupMessage and SSLRequest have
// no type tag (they are distinguished by position in the connection); every
// other message carries its ASCII type tag.
enum FrontendMessage {

    static let protocolVersion: Int32 = 196608
    static let sslRequestCode: Int32 = 80877103

    private static let tagPassword: UInt8 = 0x70
    private static let tagQuery: UInt8 = 0x51
    private static let tagParse: UInt8 = 0x50
    private static let tagBind: UInt8 = 0x42
    private static let tagDescribe: UInt8 = 0x44
    private static let tagExecute: UInt8 = 0x45
    private static let tagSync: UInt8 = 0x53
    private static let tagTerminate: UInt8 = 0x58
    private static let tagCopyData: UInt8 = 0x64
    private static let tagCopyDone: UInt8 = 0x63
    private static let tagCopyFail: UInt8 = 0x66
    private static let describeStatementTarget: UInt8 = 0x53
    private static let describePortalTarget: UInt8 = 0x50
    private static let textFormatCode: Int16 = 0
    private static let binaryFormatCode: Int16 = 1

    static func startup(user: String, database: String, applicationName: String, allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: 96)
        let lengthIndex = buffer.writerIndex
        buffer.writeInteger(Int32(0))
        buffer.writeInteger(protocolVersion)
        writeStartupParameters(into: &buffer, user: user, database: database, applicationName: applicationName)
        buffer.writeInteger(UInt8(0))
        buffer.backpatchLength(at: lengthIndex)
        return buffer
    }

    private static func writeStartupParameters(into buffer: inout ByteBuffer, user: String, database: String, applicationName: String) {
        buffer.writeCString("user")
        buffer.writeCString(user)
        buffer.writeCString("database")
        buffer.writeCString(database)
        buffer.writeCString("application_name")
        buffer.writeCString(applicationName)
        buffer.writeCString("client_encoding")
        buffer.writeCString("UTF8")
    }

    static func sslRequest(allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: 8)
        buffer.writeInteger(Int32(8))
        buffer.writeInteger(sslRequestCode)
        return buffer
    }

    static func password(_ bytes: [UInt8], allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: bytes.count + 6)
        let lengthIndex = buffer.writeMessageLengthPrefix(tag: tagPassword)
        buffer.writeBytes(bytes)
        buffer.writeInteger(UInt8(0))
        buffer.backpatchLength(at: lengthIndex)
        return buffer
    }

    static func saslInitialResponse(mechanism: String, initialResponse: [UInt8], allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: mechanism.utf8.count + initialResponse.count + 16)
        let lengthIndex = buffer.writeMessageLengthPrefix(tag: tagPassword)
        buffer.writeCString(mechanism)
        buffer.writeInteger(Int32(initialResponse.count))
        buffer.writeBytes(initialResponse)
        buffer.backpatchLength(at: lengthIndex)
        return buffer
    }

    static func saslResponse(_ bytes: [UInt8], allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: bytes.count + 6)
        let lengthIndex = buffer.writeMessageLengthPrefix(tag: tagPassword)
        buffer.writeBytes(bytes)
        buffer.backpatchLength(at: lengthIndex)
        return buffer
    }

    static func appendQuery(into buffer: inout ByteBuffer, sql: String) {
        let lengthIndex = buffer.writeMessageLengthPrefix(tag: tagQuery)
        buffer.writeCString(sql)
        buffer.backpatchLength(at: lengthIndex)
    }

    static func parse(statementName: String, sql: String, allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: sql.utf8.count + statementName.utf8.count + 12)
        appendParse(into: &buffer, statementName: statementName, sql: sql)
        return buffer
    }

    // Append-in-place variants write one message directly into a shared buffer,
    // so the extended-query path builds Parse/Bind/Describe/Execute/Sync as a
    // single allocation instead of one throwaway buffer per message plus a copy.
    static func appendParse(into buffer: inout ByteBuffer, statementName: String, sql: String) {
        let lengthIndex = buffer.writeMessageLengthPrefix(tag: tagParse)
        buffer.writeCString(statementName)
        buffer.writeCString(sql)
        buffer.writeInteger(Int16(0))
        buffer.backpatchLength(at: lengthIndex)
    }

    // Binds parameters in text format and requests results in text format, so a
    // Parameters are bound in text format (a single 0 format code stands for
    // "every parameter is text") and the server coerces them to each column type.
    // Results are requested in binary format (a single 1 code stands for "every
    // column is binary"), which is both faster to decode and exact for floating
    // point, timestamps, UUIDs, and bytea. The simple query protocol has no such
    // choice and always returns text, so the row decoders handle both formats.
    static func bind(portalName: String, statementName: String, parameters: [PostgresCell], allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: 64)
        appendBind(into: &buffer, portalName: portalName, statementName: statementName, parameters: parameters)
        return buffer
    }

    static func appendBind(into buffer: inout ByteBuffer, portalName: String, statementName: String, parameters: [PostgresCell]) {
        let lengthIndex = buffer.writeMessageLengthPrefix(tag: tagBind)
        buffer.writeCString(portalName)
        buffer.writeCString(statementName)
        buffer.writeInteger(Int16(1))
        buffer.writeInteger(textFormatCode)
        writeBindParameters(into: &buffer, parameters: parameters)
        buffer.writeInteger(Int16(1))
        buffer.writeInteger(binaryFormatCode)
        buffer.backpatchLength(at: lengthIndex)
    }

    static func appendBindTextResult(into buffer: inout ByteBuffer, statementName: String, parameters: [PostgresCell]) {
        let lengthIndex = buffer.writeMessageLengthPrefix(tag: tagBind)
        buffer.writeCString("")
        buffer.writeCString(statementName)
        buffer.writeInteger(Int16(1))
        buffer.writeInteger(textFormatCode)
        writeBindParameters(into: &buffer, parameters: parameters)
        buffer.writeInteger(Int16(0))
        buffer.backpatchLength(at: lengthIndex)
    }

    static func appendBindInt64(into buffer: inout ByteBuffer, statementName: String, value: Int64) {
        let lengthIndex = buffer.writeMessageLengthPrefix(tag: tagBind)
        buffer.writeCString("")
        buffer.writeCString(statementName)
        buffer.writeInteger(Int16(1))
        buffer.writeInteger(textFormatCode)
        buffer.writeInteger(Int16(1))
        appendInt64TextParameter(value, into: &buffer)
        buffer.writeInteger(Int16(1))
        buffer.writeInteger(binaryFormatCode)
        buffer.backpatchLength(at: lengthIndex)
    }

    private static func appendInt64TextParameter(_ value: Int64, into buffer: inout ByteBuffer) {
        let negative = value < 0
        let magnitude = unsignedMagnitude(of: value)
        let digits = decimalDigitCount(of: magnitude)
        buffer.writeInteger(Int32(negative ? digits + 1 : digits))
        if negative { buffer.writeInteger(UInt8(0x2D)) }
        writeDecimalDigits(magnitude, count: digits, into: &buffer)
    }

    private static func unsignedMagnitude(of value: Int64) -> UInt64 {
        value < 0 ? (~UInt64(bitPattern: value) &+ 1) : UInt64(bitPattern: value)
    }

    private static func decimalDigitCount(of magnitude: UInt64) -> Int {
        var count = 1
        var scan = magnitude
        while scan >= 10 { scan /= 10; count += 1 }
        return count
    }

    private static func writeDecimalDigits(_ magnitude: UInt64, count: Int, into buffer: inout ByteBuffer) {
        var divisor: UInt64 = 1
        for _ in 1..<count { divisor *= 10 }
        var remainder = magnitude
        while divisor > 0 {
            buffer.writeInteger(UInt8(0x30) &+ UInt8(remainder / divisor))
            remainder %= divisor
            divisor /= 10
        }
    }

    private static func writeBindParameters(into buffer: inout ByteBuffer, parameters: [PostgresCell]) {
        buffer.writeInteger(Int16(bitPattern: UInt16(parameters.count)))
        for parameter in parameters {
            writeBindParameter(into: &buffer, parameter: parameter)
        }
    }

    private static func writeBindParameter(into buffer: inout ByteBuffer, parameter: PostgresCell) {
        switch parameter {
        case .sqlNull: buffer.writeInteger(Int32(-1))
        case .bytes(let bytes):
            buffer.writeInteger(Int32(bytes.count))
            buffer.writeBytes(bytes)
        }
    }

    static func describePortal(name: String, allocator: ByteBufferAllocator) -> ByteBuffer {
        describe(target: describePortalTarget, name: name, allocator: allocator)
    }

    static func describeStatement(name: String, allocator: ByteBufferAllocator) -> ByteBuffer {
        describe(target: describeStatementTarget, name: name, allocator: allocator)
    }

    private static func describe(target: UInt8, name: String, allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: name.utf8.count + 8)
        appendDescribe(into: &buffer, target: target, name: name)
        return buffer
    }

    static func appendDescribePortal(into buffer: inout ByteBuffer, name: String) {
        appendDescribe(into: &buffer, target: describePortalTarget, name: name)
    }

    private static func appendDescribe(into buffer: inout ByteBuffer, target: UInt8, name: String) {
        let lengthIndex = buffer.writeMessageLengthPrefix(tag: tagDescribe)
        buffer.writeInteger(target)
        buffer.writeCString(name)
        buffer.backpatchLength(at: lengthIndex)
    }

    static func execute(portalName: String, maxRows: Int32, allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: portalName.utf8.count + 12)
        appendExecute(into: &buffer, portalName: portalName, maxRows: maxRows)
        return buffer
    }

    static func appendExecute(into buffer: inout ByteBuffer, portalName: String, maxRows: Int32) {
        let lengthIndex = buffer.writeMessageLengthPrefix(tag: tagExecute)
        buffer.writeCString(portalName)
        buffer.writeInteger(maxRows)
        buffer.backpatchLength(at: lengthIndex)
    }

    static func sync(allocator: ByteBufferAllocator) -> ByteBuffer {
        emptyBody(tag: tagSync, allocator: allocator)
    }

    static func appendSync(into buffer: inout ByteBuffer) {
        let lengthIndex = buffer.writeMessageLengthPrefix(tag: tagSync)
        buffer.backpatchLength(at: lengthIndex)
    }

    static func terminate(allocator: ByteBufferAllocator) -> ByteBuffer {
        emptyBody(tag: tagTerminate, allocator: allocator)
    }

    static func copyData(payload: ByteBuffer, allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: payload.readableBytes + 5)
        let lengthIndex = buffer.writeMessageLengthPrefix(tag: tagCopyData)
        var payload = payload
        buffer.writeBuffer(&payload)
        buffer.backpatchLength(at: lengthIndex)
        return buffer
    }

    static func copyDone(allocator: ByteBufferAllocator) -> ByteBuffer {
        emptyBody(tag: tagCopyDone, allocator: allocator)
    }

    static func copyFail(message: String, allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: message.utf8.count + 8)
        let lengthIndex = buffer.writeMessageLengthPrefix(tag: tagCopyFail)
        buffer.writeCString(message)
        buffer.backpatchLength(at: lengthIndex)
        return buffer
    }

    private static func emptyBody(tag: UInt8, allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: 5)
        let lengthIndex = buffer.writeMessageLengthPrefix(tag: tag)
        buffer.backpatchLength(at: lengthIndex)
        return buffer
    }
}
