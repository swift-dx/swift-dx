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

@Suite("ClickHouse client packet type")
struct ClickHouseClientPacketTypeTests {

    @Test("each known client type round-trips through write and read")
    func roundTripAllClientTypes() throws {
        let types: [ClickHouseClientPacketType] = [.hello, .query, .data, .cancel, .ping, .tablesStatusRequest]
        for type in types {
            var buffer = ByteBuffer()
            type.write(into: &buffer)
            let decoded = try ClickHouseClientPacketType.read(from: &buffer)
            #expect(decoded == type)
            #expect(buffer.readableBytes == 0)
        }
    }

    @Test("an unknown raw value surfaces a typed error")
    func unknownClientTypeRejected() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseUVarInt(99)
        #expect(throws: ClickHouseError.unknownClientPacketType(rawValue: 99)) {
            try ClickHouseClientPacketType.read(from: &buffer)
        }
    }

    @Test("hello marker is exactly one byte (UVarInt 0)")
    func helloMarkerIsOneByte() {
        var buffer = ByteBuffer()
        ClickHouseClientPacketType.hello.write(into: &buffer)
        #expect(buffer.readableBytes == 1)
        #expect(buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) == 0)
    }

}

@Suite("ClickHouse server packet type")
struct ClickHouseServerPacketTypeTests {

    @Test("each known server type round-trips through write and read")
    func roundTripAllServerTypes() throws {
        let types: [ClickHouseServerPacketType] = [
            .hello, .data, .exception, .progress, .pong, .endOfStream,
            .profileInfo, .totals, .extremes, .tablesStatusResponse,
            .log, .tableColumns, .partUUIDs, .readTaskRequest, .profileEvents,
        ]
        for type in types {
            var buffer = ByteBuffer()
            type.write(into: &buffer)
            let decoded = try ClickHouseServerPacketType.read(from: &buffer)
            #expect(decoded == type)
            #expect(buffer.readableBytes == 0)
        }
    }

    @Test("an unknown server raw value surfaces a typed error")
    func unknownServerTypeRejected() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseUVarInt(200)
        #expect(throws: ClickHouseError.unknownServerPacketType(rawValue: 200)) {
            try ClickHouseServerPacketType.read(from: &buffer)
        }
    }

    @Test("server type markers do not collide with client type markers in semantics")
    func serverAndClientMarkersAreSemantic() {
        #expect(ClickHouseClientPacketType.hello.rawValue == ClickHouseServerPacketType.hello.rawValue)
        #expect(ClickHouseClientPacketType.data.rawValue == ClickHouseServerPacketType.data.rawValue + 1)
    }

}
