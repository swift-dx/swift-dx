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

// Inverse of `ClickHouseServerPacketReader`: writes the marker UVarInt
// then the body for any client packet variant we emit. The Data packet
// always carries a (possibly empty) table name before the block, per
// CH's wire convention.
//
// `ClickHouseClientPacket.cancel` and `.ping` are marker-only — they
// have no body, so writing the marker is the entire packet.
enum ClickHouseClientPacketWriter {

    static func write(
        _ packet: ClickHouseClientPacket,
        into buffer: inout ByteBuffer,
        revision: UInt64,
        compression: ClickHouseCompressionMethod = .uncompressed
    ) throws {
        switch packet {
        case .hello(let body): writeHello(body: body, into: &buffer)
        case .query(let body): try writeQuery(body: body, revision: revision, into: &buffer)
        case .data(let tableName, let block): try writeData(tableName: tableName, block: block, revision: revision, compression: compression, into: &buffer)
        case .cancel: ClickHouseClientPacketType.cancel.write(into: &buffer)
        case .ping: ClickHouseClientPacketType.ping.write(into: &buffer)
        }
    }

    private static func writeHello(body: ClickHouseClientHelloPacket, into buffer: inout ByteBuffer) {
        ClickHouseClientPacketType.hello.write(into: &buffer)
        body.encode(into: &buffer)
    }

    private static func writeQuery(body: ClickHouseQueryPacket, revision: UInt64, into buffer: inout ByteBuffer) throws {
        ClickHouseClientPacketType.query.write(into: &buffer)
        try body.encode(into: &buffer, revision: revision)
    }

    private static func writeData(tableName: String, block: ClickHouseBlock, revision: UInt64, compression: ClickHouseCompressionMethod, into buffer: inout ByteBuffer) throws {
        ClickHouseClientPacketType.data.write(into: &buffer)
        buffer.writeClickHouseString(tableName)
        try writeBlockBody(block: block, revision: revision, compression: compression, into: &buffer)
    }

    // Wire convention: when compression is negotiated, every block in a
    // Data packet is wrapped in a compression frame (16-byte CityHash
    // checksum + method byte + sizes + payload). When compression is
    // off, block bytes go through verbatim. The table_name is always
    // uncompressed.
    private static func writeBlockBody(
        block: ClickHouseBlock,
        revision: UInt64,
        compression: ClickHouseCompressionMethod,
        into buffer: inout ByteBuffer
    ) throws {
        switch compression {
        case .uncompressed:
            try block.encode(into: &buffer, revision: revision)
        case .lz4:
            var blockBytes = ByteBuffer()
            try block.encode(into: &blockBytes, revision: revision)
            var frame = try ClickHouseCompressionFrame.encode(data: blockBytes, method: .lz4)
            buffer.writeBuffer(&frame)
        case .zstd:
            throw ClickHouseError.compressionFrameMethodUnsupported(methodRawValue: compression.rawValue, methodName: String(describing: compression))
        }
    }

}
