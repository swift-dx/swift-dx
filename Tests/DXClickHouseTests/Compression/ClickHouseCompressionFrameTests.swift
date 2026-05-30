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

// Frame byte vectors generated from `clickhouse/ch-go`'s `compress.NewWriter`
// with `LZ4` and `None` methods. To regenerate, write a small Go program
// that imports `github.com/ClickHouse/ch-go/compress` and calls
// `w := compress.NewWriter(0, method); w.Compress(payload); print w.Data`.
@Suite("ClickHouse compression frame decoder")
struct ClickHouseCompressionFrameTests {

    // LZ4-compressed "Hello, World!" — 39 bytes, payload 13 bytes.
    private static let lz4HelloWorld: [UInt8] = [
        0x29, 0x0a, 0xb3, 0x31, 0x78, 0xce, 0x49, 0xa2, 0xda, 0xf1, 0xbb, 0x91,
        0x4b, 0xd9, 0xd3, 0x20, 0x82, 0x17, 0x00, 0x00, 0x00, 0x0d, 0x00, 0x00,
        0x00, 0xd0, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x2c, 0x20, 0x57, 0x6f, 0x72,
        0x6c, 0x64, 0x21
    ]

    // LZ4-compressed empty input — 26 bytes, payload 0 bytes.
    private static let lz4Empty: [UInt8] = [
        0x12, 0xb8, 0x3a, 0x60, 0x2b, 0xd7, 0xde, 0x6d, 0xf4, 0x49, 0x15, 0x04,
        0x1a, 0x40, 0xdb, 0x2b, 0x82, 0x0a, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00
    ]

    // LZ4-compressed 1024 zero bytes — 51 bytes, highly compressible.
    private static let lz41024Zeros: [UInt8] = [
        0x57, 0x88, 0xa9, 0x19, 0x01, 0x88, 0x78, 0xac, 0x29, 0x37, 0xf5, 0x8a,
        0x04, 0x6a, 0xb8, 0x17, 0x82, 0x23, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00,
        0x00, 0x1f, 0x00, 0x01, 0x00, 0xff, 0xff, 0xff, 0xdc, 0x00, 0x02, 0x00,
        0x00, 0x02, 0x00, 0xb0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00
    ]

    // Method=None "Hello, World!" — 38 bytes, raw payload of 13 bytes.
    private static let noneHelloWorld: [UInt8] = [
        0x1e, 0x40, 0x08, 0x31, 0xdb, 0x8e, 0x36, 0x33, 0x38, 0x01, 0xac, 0x8b,
        0x0d, 0x9e, 0x87, 0xee, 0x02, 0x16, 0x00, 0x00, 0x00, 0x0d, 0x00, 0x00,
        0x00, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x2c, 0x20, 0x57, 0x6f, 0x72, 0x6c,
        0x64, 0x21
    ]

    @Test("a valid LZ4-compressed frame decompresses to its original payload")
    func lz4FrameDecompresses() throws {
        var buffer = ByteBuffer(bytes: Self.lz4HelloWorld)
        let result = try ClickHouseCompressionFrame.decode(from: &buffer)
        #expect(Array(result.readableBytesView) == Array("Hello, World!".utf8))
        #expect(buffer.readableBytes == 0, "decoder should consume the entire frame")
    }

    @Test("an LZ4 frame for empty input decompresses to an empty buffer")
    func lz4EmptyFrameDecompresses() throws {
        var buffer = ByteBuffer(bytes: Self.lz4Empty)
        let result = try ClickHouseCompressionFrame.decode(from: &buffer)
        #expect(result.readableBytes == 0)
        #expect(buffer.readableBytes == 0)
    }

    @Test("an LZ4 frame for 1024 zero bytes decompresses to 1024 zero bytes")
    func lz4LargeFrameDecompresses() throws {
        var buffer = ByteBuffer(bytes: Self.lz41024Zeros)
        let result = try ClickHouseCompressionFrame.decode(from: &buffer)
        #expect(result.readableBytes == 1024)
        #expect(Array(result.readableBytesView) == Array(repeating: UInt8(0), count: 1024))
    }

    @Test("a valid uncompressed (method=None) frame returns the raw payload")
    func noneFrameReturnsRawPayload() throws {
        var buffer = ByteBuffer(bytes: Self.noneHelloWorld)
        let result = try ClickHouseCompressionFrame.decode(from: &buffer)
        #expect(Array(result.readableBytesView) == Array("Hello, World!".utf8))
    }

    @Test("a frame with a flipped checksum byte fails with checksumMismatch")
    func corruptedChecksumThrows() {
        var bytes = Self.lz4HelloWorld
        bytes[0] ^= 0xFF
        var buffer = ByteBuffer(bytes: bytes)
        #expect(throws: ClickHouseError.self) {
            try ClickHouseCompressionFrame.decode(from: &buffer)
        }
    }

    @Test("a frame with a flipped payload byte fails with checksumMismatch")
    func corruptedPayloadThrows() {
        var bytes = Self.lz4HelloWorld
        bytes[27] ^= 0x01 // flip a payload byte
        var buffer = ByteBuffer(bytes: bytes)
        #expect(throws: ClickHouseError.self) {
            try ClickHouseCompressionFrame.decode(from: &buffer)
        }
    }

    @Test("a buffer shorter than the 25-byte header is reported as truncated")
    func headerTruncationThrows() {
        var buffer = ByteBuffer(bytes: Array(Self.lz4HelloWorld.prefix(20)))
        #expect(throws: ClickHouseError.self) {
            try ClickHouseCompressionFrame.decode(from: &buffer)
        }
    }

    @Test("a buffer with header but truncated payload is reported as truncated")
    func payloadTruncationThrows() {
        // 30 bytes: full 25-byte header + 5 of 14 payload bytes.
        var buffer = ByteBuffer(bytes: Array(Self.lz4HelloWorld.prefix(30)))
        #expect(throws: ClickHouseError.self) {
            try ClickHouseCompressionFrame.decode(from: &buffer)
        }
    }

    @Test("a frame with a genuinely unknown method byte (0xAB, not in the wire enum) surfaces compressionFrameUnknownMethod with the byte preserved")
    func unknownMethodThrowsTypedErrorWithRawByte() {
        // Build a synthetic frame with an unknown method byte. We can't
        // just mutate an existing frame and expect to bypass the
        // checksum check, so build the inner bytes from scratch and
        // compute a matching CityHash102 over them.
        let payload: [UInt8] = [0x01, 0x02, 0x03]
        let compressedSize = ClickHouseCompressionFrame.compressHeaderSize + payload.count
        var inner = ByteBuffer()
        inner.writeInteger(UInt8(0xAB))
        inner.writeInteger(UInt32(compressedSize), endianness: .little)
        inner.writeInteger(UInt32(payload.count), endianness: .little)
        inner.writeBytes(payload)
        let checksum = ClickHouseCityHash102.hash128(inner.readableBytesView)

        var frame = ByteBuffer()
        frame.writeInteger(checksum.low, endianness: .little)
        frame.writeInteger(checksum.high, endianness: .little)
        var innerCopy = inner
        frame.writeBuffer(&innerCopy)

        var buffer = frame
        var thrown: Error?
        do {
            _ = try ClickHouseCompressionFrame.decode(from: &buffer)
        } catch {
            thrown = error
        }
        // Pin the specific variant: 0xAB is not in `ClickHouseCompressionMethod`,
        // so it must be the "unknown" kind, not the "method-unsupported" kind
        // (the latter is reserved for known-but-unsupported bytes like ZSTD).
        let received = thrown as? ClickHouseError
        #expect(received == .compressionFrameUnknownMethod(rawValue: 0xAB))
    }

    @Test("a method=None frame whose declared uncompressed size disagrees with payload length is rejected")
    func nonePayloadSizeMismatchThrows() {
        // Build a synthetic None-method frame with payload=3 but uncompressed_size=5.
        let payload: [UInt8] = [0x10, 0x20, 0x30]
        let compressedSize = ClickHouseCompressionFrame.compressHeaderSize + payload.count
        var inner = ByteBuffer()
        inner.writeInteger(UInt8(0x02))
        inner.writeInteger(UInt32(compressedSize), endianness: .little)
        inner.writeInteger(UInt32(5), endianness: .little) // declared length is wrong
        inner.writeBytes(payload)
        let checksum = ClickHouseCityHash102.hash128(inner.readableBytesView)

        var frame = ByteBuffer()
        frame.writeInteger(checksum.low, endianness: .little)
        frame.writeInteger(checksum.high, endianness: .little)
        var innerCopy = inner
        frame.writeBuffer(&innerCopy)

        var buffer = frame
        #expect(throws: ClickHouseError.self) {
            try ClickHouseCompressionFrame.decode(from: &buffer)
        }
    }

    @Test("a frame with compressed_size below the 9-byte header floor is rejected")
    func compressedSizeUnderFloorThrows() {
        // Build a frame where the compressed_size field claims a smaller value than 9 (the header).
        var inner = ByteBuffer()
        inner.writeInteger(UInt8(0x82))
        inner.writeInteger(UInt32(5), endianness: .little) // claims compressed_size=5, but header alone is 9
        inner.writeInteger(UInt32(0), endianness: .little)
        let checksum = ClickHouseCityHash102.hash128(inner.readableBytesView)

        var frame = ByteBuffer()
        frame.writeInteger(checksum.low, endianness: .little)
        frame.writeInteger(checksum.high, endianness: .little)
        var innerCopy = inner
        frame.writeBuffer(&innerCopy)

        var buffer = frame
        #expect(throws: ClickHouseError.self) {
            try ClickHouseCompressionFrame.decode(from: &buffer)
        }
    }

    // MARK: - Encoder

    @Test("encoded uncompressed frame matches the Go reference byte-for-byte")
    func encodedUncompressedFrameByteExactWithReference() throws {
        // The Go reference (`ch-go compress.NewWriter(0, None).Compress("Hello, World!")`)
        // produces `Self.noneHelloWorld`. Since the .uncompressed path passes the data
        // through verbatim, the CityHash input is identical between Swift and Go, so the
        // checksum and the entire frame must byte-equal.
        let data = ByteBuffer(bytes: Array("Hello, World!".utf8))
        let encoded = try ClickHouseCompressionFrame.encode(data: data, method: .uncompressed)
        #expect(Array(encoded.readableBytesView) == Self.noneHelloWorld)
    }

    @Test("encoded LZ4 frame round-trips through the decoder back to the original data")
    func roundTripLZ4() throws {
        let original = Array("the quick brown fox jumps over the lazy dog repeatedly".utf8)
        let data = ByteBuffer(bytes: original)
        var encoded = try ClickHouseCompressionFrame.encode(data: data, method: .lz4)
        let decoded = try ClickHouseCompressionFrame.decode(from: &encoded)
        #expect(Array(decoded.readableBytesView) == original)
        #expect(encoded.readableBytes == 0, "decoder consumes the entire encoded frame")
    }

    @Test("encoded uncompressed frame round-trips through the decoder")
    func roundTripUncompressed() throws {
        let original = Array("uncompressed payload that should be passed verbatim".utf8)
        let data = ByteBuffer(bytes: original)
        var encoded = try ClickHouseCompressionFrame.encode(data: data, method: .uncompressed)
        let decoded = try ClickHouseCompressionFrame.decode(from: &encoded)
        #expect(Array(decoded.readableBytesView) == original)
    }

    @Test("encoded LZ4 frame for empty data round-trips back to empty")
    func roundTripLZ4Empty() throws {
        var encoded = try ClickHouseCompressionFrame.encode(data: ByteBuffer(), method: .lz4)
        let decoded = try ClickHouseCompressionFrame.decode(from: &encoded)
        #expect(decoded.readableBytes == 0)
    }

    @Test("encoded LZ4 frame for highly compressible 4096-byte input round-trips and is smaller than the input")
    func roundTripLZ4LargeCompressible() throws {
        let original = Array(repeating: UInt8(0x00), count: 4096)
        let data = ByteBuffer(bytes: original)
        var encoded = try ClickHouseCompressionFrame.encode(data: data, method: .lz4)
        let encodedSize = encoded.readableBytes
        #expect(encodedSize < 200, "highly-compressible 4096 bytes should compress well below input size")
        let decoded = try ClickHouseCompressionFrame.decode(from: &encoded)
        #expect(decoded.readableBytes == 4096)
        #expect(Array(decoded.readableBytesView) == original)
    }

    @Test("encoding with .zstd surfaces compressionFrameMethodUnsupported (known method, not yet implemented) rather than the generic 'unknown method' error")
    func encodeWithZSTDThrowsMethodUnsupported() {
        let data = ByteBuffer(bytes: [0x01, 0x02, 0x03])
        var thrown: Error?
        do {
            _ = try ClickHouseCompressionFrame.encode(data: data, method: .zstd)
        } catch {
            thrown = error
        }
        let received = thrown as? ClickHouseError
        #expect(received == .compressionFrameMethodUnsupported(methodRawValue: ClickHouseCompressionMethod.zstd.rawValue, methodName: "zstd"))
    }

    @Test("encoded frame has exactly the expected size: 16 + 9 + payload")
    func encodedFrameSizeIsCorrect() throws {
        let data = ByteBuffer(bytes: Array("payload".utf8))
        let encodedUncompressed = try ClickHouseCompressionFrame.encode(data: data, method: .uncompressed)
        #expect(encodedUncompressed.readableBytes == 16 + 9 + data.readableBytes)

        let encodedLZ4 = try ClickHouseCompressionFrame.encode(data: data, method: .lz4)
        // For 7-byte input below the LZ4 floor, payload becomes a literal-only sequence
        // with one extra token byte: payload = 7 + 1 = 8 bytes.
        #expect(encodedLZ4.readableBytes == 16 + 9 + 8)
    }

    @Test("encoded frame's checksum is correctly computed (decode validates it)")
    func encodedFrameChecksumValid() throws {
        // If the encoder's checksum were wrong, the decoder would throw.
        // This test confirms the decoder accepts every encoded frame across the full size range.
        for size in [0, 1, 9, 25, 26, 100, 1000] {
            let original = (0..<size).map { UInt8($0 & 0xFF) }
            let data = ByteBuffer(bytes: original)
            var encoded = try ClickHouseCompressionFrame.encode(data: data, method: .lz4)
            let decoded = try ClickHouseCompressionFrame.decode(from: &encoded)
            #expect(Array(decoded.readableBytesView) == original, "size=\(size) round-trip")
        }
    }

    // MARK: - Decoder (continued)

    @Test("decoding stops at the end of one frame even if the buffer has trailing bytes")
    func decoderStopsAtFrameBoundary() throws {
        var concatenated = Self.lz4HelloWorld
        concatenated.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF]) // trailing junk
        var buffer = ByteBuffer(bytes: concatenated)
        let result = try ClickHouseCompressionFrame.decode(from: &buffer)
        #expect(Array(result.readableBytesView) == Array("Hello, World!".utf8))
        #expect(buffer.readableBytes == 4, "trailing 4 bytes should remain unconsumed")
        #expect(Array(buffer.readableBytesView) == [0xDE, 0xAD, 0xBE, 0xEF])
    }

}
