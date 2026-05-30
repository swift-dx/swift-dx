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

// Bridges the wire-byte layer to the typed `ClickHouseServerPacket`
// enum. Reads the UVarInt marker first, then dispatches to the right
// body decoder. Block-carrying packets share the `tableName + Block`
// shape per CH's wire convention; the table name is always read even
// when empty.
//
// Markers we recognize but don't yet decode (`tablesStatusResponse`,
// `partUUIDs`) throw `unimplementedServerPacket(type:)` — fail-safe
// against silently misframing the next packet on the wire.
enum ClickHouseServerPacketReader {

    static func read(
        from buffer: inout ByteBuffer,
        revision: UInt64,
        compression: ClickHouseCompressionMethod = .uncompressed
    ) throws -> ClickHouseServerPacket {
        let type = try ClickHouseServerPacketType.read(from: &buffer)
        switch type {
        case .hello: return .hello(try ClickHouseServerHelloPacket.decode(from: &buffer, clientRevision: revision))
        case .data: return try readTableBlock(from: &buffer, revision: revision, compression: compression, wrap: ClickHouseServerPacket.data)
        case .exception: return .exception(try ClickHouseServerExceptionPacket.decode(from: &buffer))
        case .progress: return .progress(try ClickHouseServerProgressPacket.decode(from: &buffer, revision: revision))
        case .pong: return .pong
        case .endOfStream: return .endOfStream
        case .profileInfo: return .profileInfo(try ClickHouseServerProfileInfoPacket.decode(from: &buffer, revision: revision))
        case .totals: return try readTableBlock(from: &buffer, revision: revision, compression: compression, wrap: ClickHouseServerPacket.totals)
        case .extremes: return try readTableBlock(from: &buffer, revision: revision, compression: compression, wrap: ClickHouseServerPacket.extremes)
        case .log: return try readUncompressedTableBlock(from: &buffer, revision: revision, wrap: ClickHouseServerPacket.log)
        case .tableColumns: return .tableColumns(try ClickHouseServerTableColumnsPacket.decode(from: &buffer))
        case .readTaskRequest: return .readTaskRequest
        case .profileEvents: return try readUncompressedTableBlock(from: &buffer, revision: revision, wrap: ClickHouseServerPacket.profileEvents)
        case .timezoneUpdate: return .timezoneUpdate(timezone: try buffer.readClickHouseString())
        case .tablesStatusResponse, .partUUIDs, .mergeTreeAllRangesAnnouncement, .mergeTreeReadTaskRequest, .sshChallenge:
            throw ClickHouseError.unimplementedServerPacket(packetName: String(describing: type))
        }
    }

    private static func readTableBlock(
        from buffer: inout ByteBuffer,
        revision: UInt64,
        compression: ClickHouseCompressionMethod,
        wrap: (String, ClickHouseBlock) -> ClickHouseServerPacket
    ) throws -> ClickHouseServerPacket {
        let tableName = try buffer.readClickHouseString()
        let block = try readBlockBody(from: &buffer, revision: revision, compression: compression)
        return wrap(tableName, block)
    }

    private static func readUncompressedTableBlock(
        from buffer: inout ByteBuffer,
        revision: UInt64,
        wrap: (String, ClickHouseBlock) -> ClickHouseServerPacket
    ) throws -> ClickHouseServerPacket {
        let tableName = try buffer.readClickHouseString()
        let block = try ClickHouseBlock.decode(from: &buffer, revision: revision)
        return wrap(tableName, block)
    }

    // Inverse of `ClickHouseClientPacketWriter.writeBlockBody`. When
    // compression is negotiated, the block is delivered as a compression
    // frame; we decode it to raw block bytes then parse the block. When
    // compression is off, the block bytes follow directly.
    private static func readBlockBody(
        from buffer: inout ByteBuffer,
        revision: UInt64,
        compression: ClickHouseCompressionMethod
    ) throws -> ClickHouseBlock {
        switch compression {
        case .uncompressed:
            return try ClickHouseBlock.decode(from: &buffer, revision: revision)
        case .lz4:
            var rawBytes = try ClickHouseCompressionFrame.decode(from: &buffer)
            return try ClickHouseBlock.decode(from: &rawBytes, revision: revision)
        case .zstd:
            throw ClickHouseError.compressionFrameMethodUnsupported(methodRawValue: compression.rawValue, methodName: String(describing: compression))
        }
    }

}
