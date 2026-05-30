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

// ClickHouse compressed-block frame format (matches ch-go reader):
//
//     [16 bytes : CityHash128 of (method..end-of-payload), low/high LE]
//     [1  byte  : method (0x02=None, 0x82=LZ4, 0x90=ZSTD)]
//     [4  bytes : compressed_size (LE), INCLUDES the 9-byte header]
//     [4  bytes : uncompressed_size (LE)]
//     [N  bytes : compressed payload, where N = compressed_size - 9]
//
// `compressed_size` describing the byte range that the checksum
// covers (header + payload, not just payload) is unusual; it's the
// ClickHouse convention.
//
// The "no compression" method (0x02) is still wrapped in this same
// frame: the payload bytes are the uncompressed data verbatim, and
// the checksum still covers them. Useful for negotiated-but-unhelpful
// cases (e.g., very small payloads).
enum ClickHouseCompressionFrame {

    static let checksumSize = 16
    static let headerSize = 25
    static let compressHeaderSize = 9
    static let maxBlockSize = 128 * 1024 * 1024
    static let maxDataSize = 128 * 1024 * 1024

    static func decode(from buffer: inout ByteBuffer) throws -> ByteBuffer {
        try ensureBytes(in: buffer, needed: headerSize)
        let compressedSize = try peekCompressedSize(in: buffer)
        let totalFrameSize = checksumSize + compressedSize
        try ensureBytes(in: buffer, needed: totalFrameSize)
        guard var frame = buffer.readSlice(length: totalFrameSize) else {
            throw ClickHouseError.compressionFrameTruncated(needed: totalFrameSize, available: buffer.readableBytes)
        }
        return try parseFrame(&frame)
    }

    private static func ensureBytes(in buffer: ByteBuffer, needed: Int) throws {
        guard buffer.readableBytes >= needed else {
            throw ClickHouseError.compressionFrameTruncated(needed: needed, available: buffer.readableBytes)
        }
    }

    private static func peekCompressedSize(in buffer: ByteBuffer) throws -> Int {
        guard let raw: UInt32 = buffer.getInteger(at: buffer.readerIndex + 17, endianness: .little) else {
            throw ClickHouseError.compressionFrameTruncated(needed: 21, available: buffer.readableBytes)
        }
        let value = Int(raw)
        try requireCompressedSizeInRange(value)
        return value
    }

    private static func requireCompressedSizeInRange(_ value: Int) throws {
        guard value >= compressHeaderSize else {
            throw ClickHouseError.compressionFrameSizeOutOfRange(field: "compressed", value: value, limit: compressHeaderSize)
        }
        guard value <= maxBlockSize else {
            throw ClickHouseError.compressionFrameSizeOutOfRange(field: "compressed", value: value, limit: maxBlockSize)
        }
    }

    private static func parseFrame(_ frame: inout ByteBuffer) throws -> ByteBuffer {
        let expected = try readChecksum(from: &frame)
        let computed = ClickHouseCityHash102.hash128(frame.readableBytesView)
        guard computed == expected else {
            throw ClickHouseError.compressionFrameChecksumMismatch(
                expectedLow: expected.low,
                expectedHigh: expected.high,
                actualLow: computed.low,
                actualHigh: computed.high
            )
        }
        let header = try readHeader(from: &frame)
        try validateUncompressedSize(header.uncompressedSize)
        return try decompressPayload(
            method: header.method,
            payload: &frame,
            uncompressedSize: header.uncompressedSize
        )
    }

    private static func readChecksum(from frame: inout ByteBuffer) throws -> ClickHouseCityHash128 {
        guard let low: UInt64 = frame.readInteger(endianness: .little),
              let high: UInt64 = frame.readInteger(endianness: .little) else {
            throw ClickHouseError.compressionFrameTruncated(needed: 16, available: frame.readableBytes)
        }
        return ClickHouseCityHash128(low: low, high: high)
    }

    private struct ParsedHeader {

        let method: UInt8
        let uncompressedSize: Int

    }

    private static func readHeader(from frame: inout ByteBuffer) throws -> ParsedHeader {
        guard let method: UInt8 = frame.readInteger(),
              let _: UInt32 = frame.readInteger(endianness: .little),
              let uncompressedRaw: UInt32 = frame.readInteger(endianness: .little) else {
            throw ClickHouseError.compressionFrameTruncated(needed: compressHeaderSize, available: frame.readableBytes)
        }
        return ParsedHeader(method: method, uncompressedSize: Int(uncompressedRaw))
    }

    private static func validateUncompressedSize(_ value: Int) throws {
        guard value <= maxDataSize else {
            throw ClickHouseError.compressionFrameSizeOutOfRange(field: "uncompressed", value: value, limit: maxDataSize)
        }
    }

    private static func decompressPayload(
        method: UInt8,
        payload: inout ByteBuffer,
        uncompressedSize: Int
    ) throws -> ByteBuffer {
        switch ClickHouseCompressionMethod(rawValue: method) {
        case .lz4:
            return try ClickHouseLZ4.decompress(from: &payload, uncompressedSize: uncompressedSize)
        case .uncompressed:
            guard payload.readableBytes == uncompressedSize else {
                throw ClickHouseError.compressionFrameNonePayloadSizeMismatch(
                    expected: uncompressedSize,
                    actual: payload.readableBytes
                )
            }
            return payload
        case .zstd:
            // Known method byte (0x90), but the SDK does not currently
            // implement ZSTD decompression. The error type carries the
            // typed method so the caller can distinguish "we know what
            // this is, just can't decode it" from a genuinely unknown
            // wire byte.
            throw ClickHouseError.compressionFrameMethodUnsupported(methodRawValue: ClickHouseCompressionMethod.zstd.rawValue, methodName: "zstd")
        case .none:
            throw ClickHouseError.compressionFrameUnknownMethod(rawValue: method)
        }
    }

    static func encode(
        data: ByteBuffer,
        method: ClickHouseCompressionMethod
    ) throws -> ByteBuffer {
        let payload = try compressPayload(data: data, method: method)
        let inner = buildInner(method: method, payload: payload, uncompressedSize: data.readableBytes)
        let checksum = ClickHouseCityHash102.hash128(inner.readableBytesView)

        var frame = ByteBuffer()
        frame.reserveCapacity(checksumSize + inner.readableBytes)
        frame.writeInteger(checksum.low, endianness: .little)
        frame.writeInteger(checksum.high, endianness: .little)
        var innerCopy = inner
        frame.writeBuffer(&innerCopy)
        return frame
    }

    private static func compressPayload(
        data: ByteBuffer,
        method: ClickHouseCompressionMethod
    ) throws -> ByteBuffer {
        switch method {
        case .lz4:
            return ClickHouseLZ4.compress(data)
        case .uncompressed:
            return data
        case .zstd:
            throw ClickHouseError.compressionFrameMethodUnsupported(methodRawValue: ClickHouseCompressionMethod.zstd.rawValue, methodName: "zstd")
        }
    }

    private static func buildInner(
        method: ClickHouseCompressionMethod,
        payload: ByteBuffer,
        uncompressedSize: Int
    ) -> ByteBuffer {
        let compressedSize = compressHeaderSize + payload.readableBytes
        var inner = ByteBuffer()
        inner.reserveCapacity(compressedSize)
        inner.writeInteger(method.rawValue)
        inner.writeInteger(UInt32(compressedSize), endianness: .little)
        inner.writeInteger(UInt32(uncompressedSize), endianness: .little)
        var payloadCopy = payload
        inner.writeBuffer(&payloadCopy)
        return inner
    }

}
