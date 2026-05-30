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

// Client and server Data packet markers have DIFFERENT raw values
// (client .data = 2, server .data = 1) because they're independent
// protocols. So the tests verify each direction independently:
// - WRITE side: encode via ClickHouseClientPacketWriter, peel back the
//   marker+table_name, decompress the frame, decode the block
// - READ side: hand-build server-side wire bytes (server marker +
//   table_name + frame), call ClickHouseServerPacketReader, verify
@Suite("ClickHouse compressed Data packet wire round-trip")
struct ClickHouseCompressedDataPacketTests {

    private static let revision: UInt64 = 54_478

    @Test("client writer emits an LZ4-compressed Data packet whose payload decodes to the original block")
    func clientWriterEmitsCompressedFrame() throws {
        let original: [Int32] = [10, 20, 30, 40, 50]
        let block = Self.makeBlock(values: original)

        var bytes = ByteBuffer()
        try ClickHouseClientPacketWriter.write(
            .data(tableName: "events", block: block),
            into: &bytes,
            revision: Self.revision,
            compression: .lz4
        )

        // Wire layout: [client .data marker][table_name][compression frame]
        let marker = try ClickHouseClientPacketType.read(from: &bytes)
        #expect(marker == .data)
        let tableName = try bytes.readClickHouseString()
        #expect(tableName == "events")

        // The rest should be a compression frame containing the block bytes.
        var rawBlockBytes = try ClickHouseCompressionFrame.decode(from: &bytes)
        let decodedBlock = try ClickHouseBlock.decode(from: &rawBlockBytes, revision: Self.revision)

        let column = try #require(decodedBlock.columns.first?.column as? ClickHouseFixedWidthIntegerColumn<Int32>)
        #expect(column.values == original)
        #expect(bytes.readableBytes == 0)
    }

    @Test("client writer with .uncompressed emits raw block bytes (baseline — no behavior change)")
    func clientWriterUncompressedEmitsRawBytes() throws {
        let original: [Int32] = [1, 2, 3]
        let block = Self.makeBlock(values: original)

        var bytes = ByteBuffer()
        try ClickHouseClientPacketWriter.write(
            .data(tableName: "logs", block: block),
            into: &bytes,
            revision: Self.revision,
            compression: .uncompressed
        )

        let marker = try ClickHouseClientPacketType.read(from: &bytes)
        #expect(marker == .data)
        let tableName = try bytes.readClickHouseString()
        #expect(tableName == "logs")

        // Raw block bytes follow (NO compression frame).
        let decodedBlock = try ClickHouseBlock.decode(from: &bytes, revision: Self.revision)
        let column = try #require(decodedBlock.columns.first?.column as? ClickHouseFixedWidthIntegerColumn<Int32>)
        #expect(column.values == original)
    }

    @Test("server reader unwraps an LZ4-compressed Data packet back to the original block")
    func serverReaderUnwrapsCompressedFrame() throws {
        let original: [Int32] = [10, 20, 30]
        let block = Self.makeBlock(values: original)

        // Build server-side wire bytes manually: [server .data marker][table_name=""][frame]
        var blockBytes = ByteBuffer()
        try block.encode(into: &blockBytes, revision: Self.revision)
        var frame = try ClickHouseCompressionFrame.encode(data: blockBytes, method: .lz4)

        var bytes = ByteBuffer()
        ClickHouseServerPacketType.data.write(into: &bytes)
        bytes.writeClickHouseString("")
        bytes.writeBuffer(&frame)

        let decoded = try ClickHouseServerPacketReader.read(
            from: &bytes,
            revision: Self.revision,
            compression: .lz4
        )
        guard case .data(let tableName, let decodedBlock) = decoded else {
            Issue.record("expected .data, got \(decoded)")
            return
        }
        #expect(tableName == "")
        #expect(bytes.readableBytes == 0)
        let column = try #require(decodedBlock.columns.first?.column as? ClickHouseFixedWidthIntegerColumn<Int32>)
        #expect(column.values == original)
    }

    @Test("server reader with .uncompressed reads raw block bytes (baseline)")
    func serverReaderUncompressedReadsRawBytes() throws {
        let original: [Int32] = [1, 2, 3]
        let block = Self.makeBlock(values: original)

        var bytes = ByteBuffer()
        ClickHouseServerPacketType.data.write(into: &bytes)
        bytes.writeClickHouseString("")
        try block.encode(into: &bytes, revision: Self.revision)

        let decoded = try ClickHouseServerPacketReader.read(
            from: &bytes,
            revision: Self.revision,
            compression: .uncompressed
        )
        guard case .data(_, let decodedBlock) = decoded else {
            Issue.record("expected .data")
            return
        }
        let column = try #require(decodedBlock.columns.first?.column as? ClickHouseFixedWidthIntegerColumn<Int32>)
        #expect(column.values == original)
    }

    @Test("LZ4 compression of a 10000-row repetitive block produces output under 10% of the uncompressed size")
    func lz4CompressionShrinksRepetitiveData() throws {
        let block = Self.makeBlock(values: Array(repeating: Int32(0), count: 10_000))

        var uncompressedBytes = ByteBuffer()
        try ClickHouseClientPacketWriter.write(
            .data(tableName: "", block: block),
            into: &uncompressedBytes,
            revision: Self.revision,
            compression: .uncompressed
        )

        var compressedBytes = ByteBuffer()
        try ClickHouseClientPacketWriter.write(
            .data(tableName: "", block: block),
            into: &compressedBytes,
            revision: Self.revision,
            compression: .lz4
        )

        #expect(compressedBytes.readableBytes < uncompressedBytes.readableBytes / 10)
    }

    @Test("an empty block round-trips through compressed encoding (writer side)")
    func emptyBlockCompressedWrites() throws {
        let emptyBlock = ClickHouseBlock(blockInfo: .init(), columns: [])
        var bytes = ByteBuffer()
        try ClickHouseClientPacketWriter.write(
            .data(tableName: "", block: emptyBlock),
            into: &bytes,
            revision: Self.revision,
            compression: .lz4
        )
        // Should produce: marker + empty table_name + small frame
        let marker = try ClickHouseClientPacketType.read(from: &bytes)
        #expect(marker == .data)
        let tableName = try bytes.readClickHouseString()
        #expect(tableName == "")
        var rawBlockBytes = try ClickHouseCompressionFrame.decode(from: &bytes)
        let decodedBlock = try ClickHouseBlock.decode(from: &rawBlockBytes, revision: Self.revision)
        #expect(decodedBlock.columns.isEmpty)
    }

    @Test("a multi-column block (Int32 + String + Bool) round-trips compressed (write side)")
    func multiColumnBlockCompressedWrites() throws {
        let block = ClickHouseBlock(
            blockInfo: .init(),
            columns: [
                .init(name: "id", column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1, 2, 3])),
                .init(name: "label", column: ClickHouseStringColumn(values: ["a", "b", "c"])),
                .init(name: "active", column: ClickHouseBoolColumn(values: [true, false, true]))
            ]
        )

        var bytes = ByteBuffer()
        try ClickHouseClientPacketWriter.write(
            .data(tableName: "events", block: block),
            into: &bytes,
            revision: Self.revision,
            compression: .lz4
        )

        let marker = try ClickHouseClientPacketType.read(from: &bytes)
        #expect(marker == .data)
        _ = try bytes.readClickHouseString() // table_name
        var rawBlockBytes = try ClickHouseCompressionFrame.decode(from: &bytes)
        let decodedBlock = try ClickHouseBlock.decode(from: &rawBlockBytes, revision: Self.revision)

        #expect(decodedBlock.columns.count == 3)
        #expect(decodedBlock.rowCount == 3)
        let id = try #require(decodedBlock.columns[0].column as? ClickHouseFixedWidthIntegerColumn<Int32>)
        let label = try #require(decodedBlock.columns[1].column as? ClickHouseStringColumn)
        let active = try #require(decodedBlock.columns[2].column as? ClickHouseBoolColumn)
        #expect(id.values == [1, 2, 3])
        #expect(label.values == ["a", "b", "c"])
        #expect(active.values == [true, false, true])
    }

    @Test("non-Data client packets (Query, Cancel, Ping) are unaffected by the compression mode")
    func nonDataPacketsAreUncompressedRegardless() throws {
        let query = ClickHouseQueryPacket(queryID: "q1", queryText: "SELECT 1")
        var withLz4 = ByteBuffer()
        try ClickHouseClientPacketWriter.write(
            .query(query), into: &withLz4, revision: Self.revision, compression: .lz4
        )
        var withoutCompression = ByteBuffer()
        try ClickHouseClientPacketWriter.write(
            .query(query), into: &withoutCompression, revision: Self.revision, compression: .uncompressed
        )
        #expect(Array(withLz4.readableBytesView) == Array(withoutCompression.readableBytesView))

        var cancelLz4 = ByteBuffer()
        try ClickHouseClientPacketWriter.write(
            .cancel, into: &cancelLz4, revision: Self.revision, compression: .lz4
        )
        var cancelPlain = ByteBuffer()
        try ClickHouseClientPacketWriter.write(
            .cancel, into: &cancelPlain, revision: Self.revision, compression: .uncompressed
        )
        #expect(Array(cancelLz4.readableBytesView) == Array(cancelPlain.readableBytesView))
    }

    @Test("ZSTD compression throws since it is not yet implemented in the pipeline")
    func zstdCompressionThrows() {
        let block = Self.makeBlock(values: [1])
        var bytes = ByteBuffer()
        #expect(throws: ClickHouseError.self) {
            try ClickHouseClientPacketWriter.write(
                .data(tableName: "", block: block),
                into: &bytes,
                revision: Self.revision,
                compression: .zstd
            )
        }
    }

    @Test("a corrupted compression frame (flipped checksum byte) surfaces a checksumMismatch on decode")
    func corruptedFrameSurfacesChecksumMismatch() throws {
        let block = Self.makeBlock(values: [1, 2, 3])

        var blockBytes = ByteBuffer()
        try block.encode(into: &blockBytes, revision: Self.revision)
        var frame = try ClickHouseCompressionFrame.encode(data: blockBytes, method: .lz4)

        var bytes = ByteBuffer()
        ClickHouseServerPacketType.data.write(into: &bytes)
        bytes.writeClickHouseString("")
        bytes.writeBuffer(&frame)

        // Wire layout: [server .data marker = 1 byte][empty table_name = 1 byte][frame].
        // Frame begins at offset 2; checksum is bytes 2..17. Flip a checksum byte.
        var raw = Array(bytes.readableBytesView)
        raw[2] ^= 0xFF
        var corrupted = ByteBuffer(bytes: raw)

        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseServerPacketReader.read(
                from: &corrupted,
                revision: Self.revision,
                compression: .lz4
            )
        }
    }

    private static func makeBlock(values: [Int32]) -> ClickHouseBlock {
        ClickHouseBlock(
            blockInfo: .init(),
            columns: [
                .init(name: "n", column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: values))
            ]
        )
    }

}
