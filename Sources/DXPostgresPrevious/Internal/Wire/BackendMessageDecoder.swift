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

// Decoder for the backend (server-to-client) half of the PostgreSQL v3 wire
// protocol. `decodeOne` reads at most one complete message from the head of an
// accumulation buffer without consuming partial frames: it reports `needMore`
// until the full 1-byte tag, 4-byte length, and body are present. The inbound
// handler calls it in a loop, advancing the reader index by the reported
// `consumed` count after each successful decode.
enum BackendMessageDecoder {

    enum Step: Sendable, Equatable {

        case needMore
        case message(BackendMessage, consumed: Int)
    }

    private enum FrameLookup {

        case needMore
        case ready(tag: UInt8, bodyStart: Int, bodyLength: Int, totalLength: Int)
    }

    static func decodeOne(from buffer: ByteBuffer) throws(PostgresError) -> Step {
        switch try frameBounds(in: buffer) {
        case .needMore: return .needMore
        case .ready(let tag, let bodyStart, let bodyLength, let totalLength):
            let message = try decodeFrame(buffer, tag: tag, bodyStart: bodyStart, bodyLength: bodyLength)
            return .message(message, consumed: totalLength)
        }
    }

    private static func frameBounds(in buffer: ByteBuffer) throws(PostgresError) -> FrameLookup {
        guard buffer.readableBytes >= 5 else { return .needMore }
        let base = buffer.readerIndex
        let length = Int(buffer.getInteger(at: base + 1, as: Int32.self) ?? 0)
        try validateLength(length)
        guard buffer.readableBytes >= length + 1 else { return .needMore }
        let tag = buffer.getInteger(at: base, as: UInt8.self) ?? 0
        return .ready(tag: tag, bodyStart: base + 5, bodyLength: length - 4, totalLength: length + 1)
    }

    private static func validateLength(_ length: Int) throws(PostgresError) {
        guard length >= 4 else {
            throw PostgresError.protocolError(reason: "backend message length \(length) is below the minimum of 4")
        }
    }

    private static func decodeFrame(_ buffer: ByteBuffer, tag: UInt8, bodyStart: Int, bodyLength: Int) throws(PostgresError) -> BackendMessage {
        guard var body = buffer.getSlice(at: bodyStart, length: bodyLength) else {
            throw PostgresError.protocolError(reason: "could not slice a \(bodyLength)-byte backend message body")
        }
        return try decodeBody(tag: tag, body: &body)
    }

    private static func decodeBody(tag: UInt8, body: inout ByteBuffer) throws(PostgresError) -> BackendMessage {
        switch tag {
        case 0x52: return .authentication(try readAuthentication(&body))
        case 0x53: return try readParameterStatus(&body)
        case 0x4b: return try readBackendKeyData(&body)
        case 0x5a: return .readyForQuery(transactionStatus: try readFixedWidth(&body, as: UInt8.self))
        case 0x54: return .rowDescription(try readRowDescription(&body))
        case 0x44: return .dataRow(try readDataRow(&body))
        case 0x43: return .commandComplete(tag: try readCString(&body))
        case 0x49: return .emptyQueryResponse
        case 0x6e: return .noData
        case 0x31: return .parseComplete
        case 0x32: return .bindComplete
        case 0x33: return .closeComplete
        case 0x73: return .portalSuspended
        case 0x74: return .parameterDescription(try readParameterDescription(&body))
        case 0x47: return .copyInResponse(binaryFormat: try readFixedWidth(&body, as: Int8.self) != 0)
        case 0x45: return .error(try ServerErrorAssembler.assemble(from: readErrorFields(&body)))
        case 0x4e: return .notice(try ServerErrorAssembler.assemble(from: readErrorFields(&body)))
        case 0x41: return try readNotification(&body)
        default: throw PostgresError.protocolError(reason: "unknown backend message tag \(tag)")
        }
    }

    private static func readAuthentication(_ body: inout ByteBuffer) throws(PostgresError) -> AuthenticationRequest {
        let code = try readFixedWidth(&body, as: Int32.self)
        return try authenticationVariant(code: code, body: &body)
    }

    private static func authenticationVariant(code: Int32, body: inout ByteBuffer) throws(PostgresError) -> AuthenticationRequest {
        switch code {
        case 0: return .ok
        case 3: return .cleartextPassword
        case 5: return .md5Password(salt: readBytesRemaining(&body))
        case 10: return .saslMechanisms(try readSASLMechanisms(&body))
        case 11: return .saslContinue(data: readBytesRemaining(&body))
        case 12: return .saslFinal(data: readBytesRemaining(&body))
        default: return .unsupported(code: code)
        }
    }

    private static func readSASLMechanisms(_ body: inout ByteBuffer) throws(PostgresError) -> [String] {
        var mechanisms: [String] = []
        while body.readableBytes > 0 {
            let mechanism = try readCString(&body)
            guard !mechanism.isEmpty else { break }
            mechanisms.append(mechanism)
        }
        return mechanisms
    }

    private static func readParameterStatus(_ body: inout ByteBuffer) throws(PostgresError) -> BackendMessage {
        let name = try readCString(&body)
        let value = try readCString(&body)
        return .parameterStatus(name: name, value: value)
    }

    private static func readBackendKeyData(_ body: inout ByteBuffer) throws(PostgresError) -> BackendMessage {
        let processID = try readFixedWidth(&body, as: Int32.self)
        let secretKey = try readFixedWidth(&body, as: Int32.self)
        return .backendKeyData(processID: processID, secretKey: secretKey)
    }

    private static func readNotification(_ body: inout ByteBuffer) throws(PostgresError) -> BackendMessage {
        let processID = try readFixedWidth(&body, as: Int32.self)
        let channel = try readCString(&body)
        let payload = try readCString(&body)
        return .notification(processID: processID, channel: channel, payload: payload)
    }

    private static func readRowDescription(_ body: inout ByteBuffer) throws(PostgresError) -> [FieldDescription] {
        let count = Int(try readFixedWidth(&body, as: Int16.self))
        var fields: [FieldDescription] = []
        fields.reserveCapacity(count)
        for _ in 0..<count {
            fields.append(try readField(&body))
        }
        return fields
    }

    private static func readField(_ body: inout ByteBuffer) throws(PostgresError) -> FieldDescription {
        let name = try readCString(&body)
        let tableObjectID = try readFixedWidth(&body, as: Int32.self)
        let columnAttributeNumber = try readFixedWidth(&body, as: Int16.self)
        let dataTypeObjectID = try readFixedWidth(&body, as: UInt32.self)
        let dataTypeSize = try readFixedWidth(&body, as: Int16.self)
        let typeModifier = try readFixedWidth(&body, as: Int32.self)
        let format = try PostgresFormat.from(code: try readFixedWidth(&body, as: Int16.self))
        return FieldDescription(name: name, tableObjectID: tableObjectID, columnAttributeNumber: columnAttributeNumber, dataTypeObjectID: dataTypeObjectID, dataTypeSize: dataTypeSize, typeModifier: typeModifier, format: format)
    }

    private static func readDataRow(_ body: inout ByteBuffer) throws(PostgresError) -> [PostgresCell] {
        let count = Int(try readFixedWidth(&body, as: Int16.self))
        var cells: [PostgresCell] = []
        cells.reserveCapacity(count)
        for _ in 0..<count {
            cells.append(try readCell(&body))
        }
        return cells
    }

    private static func readCell(_ body: inout ByteBuffer) throws(PostgresError) -> PostgresCell {
        let length = Int(try readFixedWidth(&body, as: Int32.self))
        guard length >= 0 else { return .sqlNull }
        guard let bytes = body.readBytes(length: length) else {
            throw PostgresError.protocolError(reason: "truncated DataRow column: expected \(length) bytes")
        }
        return .bytes(bytes)
    }

    private static func readParameterDescription(_ body: inout ByteBuffer) throws(PostgresError) -> [UInt32] {
        let count = Int(try readFixedWidth(&body, as: Int16.self))
        var oids: [UInt32] = []
        oids.reserveCapacity(count)
        for _ in 0..<count {
            oids.append(try readFixedWidth(&body, as: UInt32.self))
        }
        return oids
    }

    private static func readErrorFields(_ body: inout ByteBuffer) throws(PostgresError) -> [(code: UInt8, value: String)] {
        var pairs: [(code: UInt8, value: String)] = []
        while body.readableBytes > 0 {
            let code = try readFixedWidth(&body, as: UInt8.self)
            guard code != 0 else { break }
            pairs.append((code: code, value: try readCString(&body)))
        }
        return pairs
    }

    private static func readBytesRemaining(_ body: inout ByteBuffer) -> [UInt8] {
        body.readBytes(length: body.readableBytes) ?? []
    }

    private static func readFixedWidth<Value: FixedWidthInteger>(_ buffer: inout ByteBuffer, as type: Value.Type) throws(PostgresError) -> Value {
        guard let value = buffer.readInteger(endianness: .big, as: Value.self) else {
            throw PostgresError.protocolError(reason: "truncated backend message: expected \(Value.bitWidth / 8) more bytes")
        }
        return value
    }

    private static func readCString(_ buffer: inout ByteBuffer) throws(PostgresError) -> String {
        let view = buffer.readableBytesView
        guard let zeroIndex = view.firstIndex(of: 0) else {
            throw PostgresError.protocolError(reason: "unterminated C string in backend message")
        }
        let length = zeroIndex - view.startIndex
        guard let string = buffer.readString(length: length) else {
            throw PostgresError.protocolError(reason: "could not read \(length)-byte C string body")
        }
        buffer.moveReaderIndex(forwardBy: 1)
        return string
    }
}
