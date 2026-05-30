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

@testable import DXClickHouse
import NIOCore
import Testing

@Suite("ClickHouse client packet writer")
struct ClickHouseClientPacketWriterTests {

    @Test("writes the marker followed by the body for client hello")
    func writesClientHelloMarkerAndBody() throws {
        let hello = ClickHouseClientHelloPacket(
            clientName: "SwiftDX",
            versionMajor: 1, versionMinor: 0, protocolRevision: 54_478,
            defaultDatabase: "obs", username: "u", password: ""
        )
        var buffer = ByteBuffer()
        try ClickHouseClientPacketWriter.write(.hello(hello), into: &buffer, revision: 54_478)

        guard let firstByte: UInt8 = buffer.getInteger(at: buffer.readerIndex) else {
            Issue.record("expected at least one byte")
            return
        }
        #expect(firstByte == ClickHouseClientPacketType.hello.rawValue)

        _ = try ClickHouseClientPacketType.read(from: &buffer)
        let decoded = try ClickHouseClientHelloPacket.decode(from: &buffer)
        #expect(decoded == hello)
    }

    @Test("data packet writes marker + table name + block")
    func writesDataPacketWithTableName() throws {
        let block = ClickHouseBlock(
            blockInfo: .init(),
            columns: [.init(name: "x", column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1]))]
        )
        var buffer = ByteBuffer()
        try ClickHouseClientPacketWriter.write(.data(tableName: "tmp", block: block), into: &buffer, revision: 54_478)

        let type = try ClickHouseClientPacketType.read(from: &buffer)
        #expect(type == .data)
        let tableName = try buffer.readClickHouseString()
        #expect(tableName == "tmp")
        let decodedBlock = try ClickHouseBlock.decode(from: &buffer, revision: 54_478)
        #expect(decodedBlock.columnCount == 1)
    }

    @Test("cancel and ping write only the marker byte")
    func markerOnlyPacketsAreSingleUVarInt() throws {
        var cancelBuffer = ByteBuffer()
        try ClickHouseClientPacketWriter.write(.cancel, into: &cancelBuffer, revision: 54_478)
        #expect(cancelBuffer.readableBytes == 1)

        var pingBuffer = ByteBuffer()
        try ClickHouseClientPacketWriter.write(.ping, into: &pingBuffer, revision: 54_478)
        #expect(pingBuffer.readableBytes == 1)
    }

}

@Suite("ClickHouse server packet reader")
struct ClickHouseServerPacketReaderTests {

    @Test("reads server hello when the marker says hello")
    func readsServerHello() throws {
        let hello = ClickHouseServerHelloPacket(
            serverName: "ClickHouse", versionMajor: 24, versionMinor: 8, serverRevision: 54_478,
            parallelReplicasProtocolVersion: .value(0),
            serverTimezone: .value("UTC"), displayName: .value("ch-1"), versionPatch: .value(12),
            chunkedProtocolSend: .value("notchunked"), chunkedProtocolRecv: .value("notchunked"),
            passwordComplexityRules: .value([]),
            interserverSecretNonce: .value(0),
            queryPlanSerializationVersion: .value(0)
        )
        var buffer = ByteBuffer()
        ClickHouseServerPacketType.hello.write(into: &buffer)
        hello.encode(into: &buffer, clientRevision: 54_478)

        let packet = try ClickHouseServerPacketReader.read(from: &buffer, revision: 54_478)
        guard case .hello(let decoded) = packet else {
            Issue.record("expected hello case, got \(packet)")
            return
        }
        #expect(decoded == hello)
        #expect(buffer.readableBytes == 0)
    }

    @Test("reads exception when the marker says exception")
    func readsException() throws {
        let exception = ClickHouseServerExceptionPacket(
            code: 42, name: "DB::Test", message: "oops", stackTrace: "frame1", nested: .none
        )
        var buffer = ByteBuffer()
        ClickHouseServerPacketType.exception.write(into: &buffer)
        exception.encode(into: &buffer)

        let packet = try ClickHouseServerPacketReader.read(from: &buffer, revision: 54_478)
        guard case .exception(let decoded) = packet else {
            Issue.record("expected exception case")
            return
        }
        #expect(decoded == exception)
    }

    @Test("reads data with table name and block")
    func readsDataWithTableName() throws {
        let block = ClickHouseBlock(
            blockInfo: .init(),
            columns: [.init(name: "id", column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [7, 8, 9]))]
        )
        var buffer = ByteBuffer()
        ClickHouseServerPacketType.data.write(into: &buffer)
        buffer.writeClickHouseString("schema.table")
        try block.encode(into: &buffer, revision: 54_478)

        let packet = try ClickHouseServerPacketReader.read(from: &buffer, revision: 54_478)
        guard case .data(let tableName, let decodedBlock) = packet else {
            Issue.record("expected data case")
            return
        }
        #expect(tableName == "schema.table")
        let typed = try #require(decodedBlock.columns[0].column as? ClickHouseFixedWidthIntegerColumn<Int32>)
        #expect(typed.values == [7, 8, 9])
    }

    @Test("marker-only packets decode to the marker variant with no body consumed")
    func markerOnlyPacketsAreSingleByte() throws {
        let cases: [(ClickHouseServerPacketType, ClickHouseServerPacket)] = [
            (.pong, .pong), (.endOfStream, .endOfStream), (.readTaskRequest, .readTaskRequest),
        ]
        for (markerType, expected) in cases {
            var buffer = ByteBuffer()
            markerType.write(into: &buffer)
            let packet = try ClickHouseServerPacketReader.read(from: &buffer, revision: 54_478)
            switch (packet, expected) {
            case (.pong, .pong), (.endOfStream, .endOfStream), (.readTaskRequest, .readTaskRequest):
                break
            default:
                Issue.record("marker \(markerType) decoded to wrong variant")
            }
            #expect(buffer.readableBytes == 0)
        }
    }

    @Test("unimplemented server packet markers throw a typed error rather than misframing the next packet")
    func unimplementedMarkersThrow() {
        var buffer = ByteBuffer()
        ClickHouseServerPacketType.tablesStatusResponse.write(into: &buffer)
        #expect(throws: ClickHouseError.unimplementedServerPacket(packetName: "tablesStatusResponse")) {
            try ClickHouseServerPacketReader.read(from: &buffer, revision: 54_478)
        }
    }

    @Test("unknown server packet marker surfaces a typed error")
    func unknownMarkerRejected() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseUVarInt(200)
        #expect(throws: ClickHouseError.unknownServerPacketType(rawValue: 200)) {
            try ClickHouseServerPacketReader.read(from: &buffer, revision: 54_478)
        }
    }

    @Test("multiple packets back-to-back in one buffer decode in order")
    func multiplePacketsInSingleBuffer() throws {
        var buffer = ByteBuffer()
        ClickHouseServerPacketType.pong.write(into: &buffer)
        ClickHouseServerPacketType.endOfStream.write(into: &buffer)
        ClickHouseServerPacketType.readTaskRequest.write(into: &buffer)

        let p1 = try ClickHouseServerPacketReader.read(from: &buffer, revision: 54_478)
        let p2 = try ClickHouseServerPacketReader.read(from: &buffer, revision: 54_478)
        let p3 = try ClickHouseServerPacketReader.read(from: &buffer, revision: 54_478)
        switch (p1, p2, p3) {
        case (.pong, .endOfStream, .readTaskRequest):
            break
        default:
            Issue.record("packets out of order: \(p1) \(p2) \(p3)")
        }
        #expect(buffer.readableBytes == 0)
    }

}
