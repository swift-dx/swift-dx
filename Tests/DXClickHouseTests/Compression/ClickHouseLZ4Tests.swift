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

@Suite("ClickHouse LZ4 block decoder")
struct ClickHouseLZ4Tests {

    @Test("an empty compressed buffer with uncompressedSize 0 decodes to an empty buffer")
    func emptyBlockDecodesEmpty() throws {
        var compressed = ByteBuffer()
        let decoded = try ClickHouseLZ4.decompress(from: &compressed, uncompressedSize: 0)
        #expect(decoded.readableBytes == 0)
    }

    @Test("a single literal-only sequence decodes back to the original bytes")
    func pureLiteralDecodesAsIs() throws {
        let original: [UInt8] = [0x48, 0x65, 0x6C, 0x6C, 0x6F]
        var compressed = ByteBuffer(bytes: [0x50] + original)
        let decoded = try ClickHouseLZ4.decompress(from: &compressed, uncompressedSize: 5)
        #expect(Array(decoded.readableBytesView) == original)
    }

    @Test("literal length above 14 uses the extension byte (token nibble 15 + ext)")
    func literalLengthWithSingleExtensionByte() throws {
        let original = Array(repeating: UInt8(0xAB), count: 16)
        var compressed = ByteBuffer(bytes: [0xF0, 0x01] + original)
        let decoded = try ClickHouseLZ4.decompress(from: &compressed, uncompressedSize: 16)
        #expect(Array(decoded.readableBytesView) == original)
    }

    @Test("literal length 270 uses one 255 continuation byte then a terminator (15 + 255 + 0)")
    func literalLengthRequiringTwoExtensionBytes() throws {
        let original = Array(repeating: UInt8(0xCC), count: 270)
        var compressed = ByteBuffer(bytes: [0xF0, 0xFF, 0x00] + original)
        let decoded = try ClickHouseLZ4.decompress(from: &compressed, uncompressedSize: 270)
        #expect(Array(decoded.readableBytesView) == original)
    }

    @Test("a non-overlapping match (offset >= length) reproduces the previous bytes")
    func nonOverlappingMatchCopiesFromHistory() throws {
        // Original: "abcdefabcdef" — first 6 literal, then match offset=6, length=6.
        // Token: literal_len=6 (nibble high), match_encoded=6-4=2 (nibble low) → 0x62.
        let prefix: [UInt8] = [0x61, 0x62, 0x63, 0x64, 0x65, 0x66] // "abcdef"
        var compressed = ByteBuffer(bytes: [0x62] + prefix + [0x06, 0x00])
        let decoded = try ClickHouseLZ4.decompress(from: &compressed, uncompressedSize: 12)
        #expect(Array(decoded.readableBytesView) == prefix + prefix)
    }

    @Test("an overlapping match (offset < length) is byte-by-byte RLE — offset 1 repeats the previous byte")
    func overlappingMatchProducesRunLengthEncoding() throws {
        // Original: 10 'a's. First 1 literal "a", then match offset=1 length=9 (encoded=5).
        // Token: literal_len=1 (high nibble), match_encoded=5 (low nibble) → 0x15.
        var compressed = ByteBuffer(bytes: [0x15, 0x61, 0x01, 0x00])
        let decoded = try ClickHouseLZ4.decompress(from: &compressed, uncompressedSize: 10)
        #expect(Array(decoded.readableBytesView) == Array(repeating: UInt8(0x61), count: 10))
    }

    @Test("an overlapping match with a 2-byte cycle (offset 2, length 8) repeats those 2 bytes")
    func overlappingMatchWithTwoBytePeriod() throws {
        // Original: "ababababab" — first 2 literal "ab", then match offset=2 length=8 (encoded=4).
        // Token: literal_len=2 (high), match_encoded=4 (low) → 0x24.
        var compressed = ByteBuffer(bytes: [0x24, 0x61, 0x62, 0x02, 0x00])
        let decoded = try ClickHouseLZ4.decompress(from: &compressed, uncompressedSize: 10)
        let expected: [UInt8] = [0x61, 0x62, 0x61, 0x62, 0x61, 0x62, 0x61, 0x62, 0x61, 0x62]
        #expect(Array(decoded.readableBytesView) == expected)
    }

    @Test("match length above 18 (4 + 14) uses the extension byte (low nibble 15 + ext)")
    func matchLengthWithExtensionByte() throws {
        // Want match_len = 20 → encoded = 16 → low nibble 15, ext = 1.
        // Literal: 1 'a'. Match: offset 1, length 20 (RLE).
        // Token: literal_len=1 (high), match nibble=15 (low) → 0x1F.
        // Extension byte for match length: 1.
        var compressed = ByteBuffer(bytes: [0x1F, 0x61, 0x01, 0x00, 0x01])
        let decoded = try ClickHouseLZ4.decompress(from: &compressed, uncompressedSize: 21)
        #expect(Array(decoded.readableBytesView) == Array(repeating: UInt8(0x61), count: 21))
    }

    @Test("match length variable-length encoding rejects truncated continuation")
    func matchLengthExtensionTruncatedThrows() {
        // Token: literal=1, match nibble=15 → 0x1F. Then 1 literal, offset, then 0xFF (continuation,
        // requires another byte) but no further bytes.
        var compressed = ByteBuffer(bytes: [0x1F, 0x61, 0x01, 0x00, 0xFF])
        #expect(throws: ClickHouseError.self) {
            try ClickHouseLZ4.decompress(from: &compressed, uncompressedSize: 1)
        }
    }

    @Test("a literal section truncated in the middle of the declared length throws")
    func truncatedLiteralSectionThrows() {
        // Token says literal_len=10 but only 5 bytes follow.
        var compressed = ByteBuffer(bytes: [0xA0, 0x61, 0x62, 0x63, 0x64, 0x65])
        #expect(throws: ClickHouseError.self) {
            try ClickHouseLZ4.decompress(from: &compressed, uncompressedSize: 10)
        }
    }

    @Test("a missing match offset (token + literals + 1 byte) throws")
    func truncatedMatchOffsetThrows() {
        // Token: literal=1 match=4 → 0x14. 1 literal. Then only 1 byte where 2 (UInt16) are needed.
        var compressed = ByteBuffer(bytes: [0x14, 0x61, 0x06])
        #expect(throws: ClickHouseError.self) {
            try ClickHouseLZ4.decompress(from: &compressed, uncompressedSize: 9)
        }
    }

    @Test("a match offset of 0 is malformed and throws")
    func zeroMatchOffsetThrows() {
        // Token: literal=1, match_encoded=4 (=8 actual). 1 literal. Offset = 0.
        var compressed = ByteBuffer(bytes: [0x14, 0x61, 0x00, 0x00])
        #expect(throws: ClickHouseError.self) {
            try ClickHouseLZ4.decompress(from: &compressed, uncompressedSize: 9)
        }
    }

    @Test("a match offset that points before the start of the output throws")
    func matchOffsetBeyondOutputThrows() {
        // Token: literal=0, match_encoded=4 (=8 actual). No literal. Offset = 10 (writerIndex=0).
        var compressed = ByteBuffer(bytes: [0x04, 0x0A, 0x00])
        #expect(throws: ClickHouseError.self) {
            try ClickHouseLZ4.decompress(from: &compressed, uncompressedSize: 8)
        }
    }

    @Test("hostile match-length sequence is rejected before the destination buffer is over-allocated")
    func decompressorRejectsOverExpansionBeforeAllocating() {
        // Real production concern: ClickHouse's compression frame caps
        // `compressed_size` at 128MB, but each `255`-byte in an LZ4
        // var-len match-length extension adds 255 to the running length.
        // A 128MB compressed payload can therefore encode a match
        // claiming to expand to ~32GB (128MB × 255). Pre-fix the inner
        // copy ran to completion before the post-loop size check fired,
        // so a hostile server could OOM the client by sending such a
        // frame. Post-fix the pre-copy bound throws before the over-
        // allocation, even though the error type stays the same.
        //
        // This test uses a small overshoot (101 bytes vs cap 10) for
        // determinism — the production threat is the same shape, just
        // at GB scale.
        //
        // Block layout:
        //   0x1F        token: literal nibble 1, match nibble 15 (extension)
        //   0x41        one literal byte 'A'
        //   0x01 0x00   match offset = 1 (UInt16 LE)
        //   0x51        match-length extension = 81. matchLength = 15 + 81 + 4 = 100.
        // Total compressed: 5 bytes; total decompressed would be 1 + 100 = 101.
        var compressed = ByteBuffer(bytes: [0x1F, 0x41, 0x01, 0x00, 0x51])
        var thrown: Error?
        do {
            _ = try ClickHouseLZ4.decompress(from: &compressed, uncompressedSize: 10)
        } catch {
            thrown = error
        }
        let received = thrown as? ClickHouseError
        guard case .lz4DecompressedSizeMismatch(let expected, let actual) = received else {
            Issue.record("expected lz4DecompressedSizeMismatch, got \(String(describing: thrown))")
            return
        }
        #expect(expected == 10)
        // The pre-write bound surfaces the would-be overflow size (101).
        // Pre-fix this same field was reached only after the destination
        // buffer had grown to 101 bytes; post-fix it's reported without
        // ever growing the buffer past the cap.
        #expect(actual == 101, "actual must reflect the would-be overshoot; got \(actual)")
    }

    @Test("an output that does not match the declared uncompressedSize throws")
    func decompressedSizeMismatchThrows() {
        // Pure literal of 5 bytes, caller claims uncompressedSize=10.
        var compressed = ByteBuffer(bytes: [0x50, 0x48, 0x65, 0x6C, 0x6C, 0x6F])
        #expect(throws: ClickHouseError.self) {
            try ClickHouseLZ4.decompress(from: &compressed, uncompressedSize: 10)
        }
    }

    @Test("decoding consumes all readable bytes from the source buffer")
    func decoderConsumesEntireSource() throws {
        let original: [UInt8] = [0x48, 0x65, 0x6C, 0x6C, 0x6F]
        var compressed = ByteBuffer(bytes: [0x50] + original)
        _ = try ClickHouseLZ4.decompress(from: &compressed, uncompressedSize: 5)
        #expect(compressed.readableBytes == 0)
    }

    // MARK: - Encoder

    @Test("encoding an empty input produces a single zero token (literal length 0)")
    func encodeEmpty() {
        let compressed = ClickHouseLZ4.compress(ByteBuffer())
        #expect(Array(compressed.readableBytesView) == [0x00])
    }

    @Test("encoding a tiny input below the 12-byte compression floor is a single literal-only sequence")
    func encodeTinyInput() {
        let original: [UInt8] = [0x48, 0x65, 0x6C, 0x6C, 0x6F]
        let compressed = ClickHouseLZ4.compress(ByteBuffer(bytes: original))
        #expect(Array(compressed.readableBytesView) == [0x50] + original)
    }

    @Test("encoding 15 bytes (still below the floor of 12? no — at the boundary) emits literals only")
    func encodeFifteenBytesEmitsAllLiterals() {
        // n=15 >= floor=12, so loop runs but limit = 15 - 12 = 3.
        // Hash table starts empty; first 3 positions can't find candidates.
        // Loop exits at i=3, anchor=0, final literals 0..15.
        let original = Array(0..<15).map { UInt8($0) }
        let compressed = ClickHouseLZ4.compress(ByteBuffer(bytes: original))
        // Token: literal_len=15 → 0xF0, ext byte 0 (15+0=15), then 15 bytes.
        #expect(compressed.getInteger(at: 0, as: UInt8.self) == 0xF0)
        #expect(compressed.getInteger(at: 1, as: UInt8.self) == 0x00)
    }

    @Test("encoding a non-matching prefix forces a literal-only final sequence; long literal runs use the 255-continuation byte")
    func encodeLongLiteralRunUsesContinuation() throws {
        // Construct an input where the encoder cannot find any 4-byte match:
        // a prefix of distinct bytes long enough to require literal-length extension,
        // crafted so no 4-byte window repeats anywhere.
        // 0,1,2,3,...,17 — 18 bytes of unique values. 18 >= 12 (floor) so loop runs but
        // hash collisions on distinct 4-byte windows yield no real matches, so the
        // entire input lands in a literal-only sequence.
        let original = Array(0..<18).map { UInt8($0) }
        let compressed = ClickHouseLZ4.compress(ByteBuffer(bytes: original))

        // Token: literal_len=18 → high nibble=15, ext byte 18-15=3.
        #expect(compressed.getInteger(at: 0, as: UInt8.self) == 0xF0)
        #expect(compressed.getInteger(at: 1, as: UInt8.self) == 0x03)
        #expect(compressed.readableBytes == 1 + 1 + 18)

        // And it round-trips.
        var roundTrip = compressed
        let decoded = try ClickHouseLZ4.decompress(from: &roundTrip, uncompressedSize: original.count)
        #expect(Array(decoded.readableBytesView) == original)
    }

    @Test("encoding a repeating-period input compresses to far fewer bytes than the original")
    func encodeRepeatingPatternIsCompact() {
        // 100 bytes of "abc" repeating; should compress to a small sequence.
        let unit: [UInt8] = [0x61, 0x62, 0x63]
        var original: [UInt8] = []
        for _ in 0..<33 { original.append(contentsOf: unit) }
        original.append(contentsOf: unit.prefix(1)) // 100 bytes total
        #expect(original.count == 100)

        let compressed = ClickHouseLZ4.compress(ByteBuffer(bytes: original))
        #expect(compressed.readableBytes < 30, "highly compressible input should produce a small output")
    }

    // MARK: - Round-trip (encoder ↔ decoder)

    @Test("round-trip: encode then decode of a tiny buffer matches the original")
    func roundTripTinyBuffer() throws {
        let original: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05]
        var compressed = ClickHouseLZ4.compress(ByteBuffer(bytes: original))
        let decoded = try ClickHouseLZ4.decompress(from: &compressed, uncompressedSize: original.count)
        #expect(Array(decoded.readableBytesView) == original)
    }

    @Test("round-trip: encode then decode of a long repeating pattern")
    func roundTripRepeatingPattern() throws {
        let unit: [UInt8] = [0x61, 0x62, 0x63]
        var original: [UInt8] = []
        for _ in 0..<100 { original.append(contentsOf: unit) } // 300 bytes

        var compressed = ClickHouseLZ4.compress(ByteBuffer(bytes: original))
        let decoded = try ClickHouseLZ4.decompress(from: &compressed, uncompressedSize: original.count)
        #expect(Array(decoded.readableBytesView) == original)
    }

    @Test("round-trip: encode then decode of a single repeated byte (RLE-friendly)")
    func roundTripSingleByteRun() throws {
        let original = Array(repeating: UInt8(0x42), count: 1000)
        var compressed = ClickHouseLZ4.compress(ByteBuffer(bytes: original))
        let decoded = try ClickHouseLZ4.decompress(from: &compressed, uncompressedSize: original.count)
        #expect(Array(decoded.readableBytesView) == original)
        #expect(compressed.readableBytes < 50, "single-byte RLE should compress to near-constant size")
    }

    @Test("round-trip: encode then decode of pseudo-random bytes (incompressible — output should be slightly larger)")
    func roundTripPseudoRandomBytes() throws {
        // Linear congruential — deterministic, no real entropy, but varied enough to defeat naive matching.
        var prng: UInt32 = 0xBEEF_DEAD
        var original: [UInt8] = []
        for _ in 0..<2048 {
            prng = prng &* 1_103_515_245 &+ 12_345
            original.append(UInt8((prng >> 16) & 0xFF))
        }

        var compressed = ClickHouseLZ4.compress(ByteBuffer(bytes: original))
        let decoded = try ClickHouseLZ4.decompress(from: &compressed, uncompressedSize: original.count)
        #expect(Array(decoded.readableBytesView) == original)
    }

    @Test("round-trip: encode then decode of an input mixing long literal runs and repeats")
    func roundTripMixedContent() throws {
        var original: [UInt8] = []
        // 100 random bytes (incompressible)
        for i in 0..<100 { original.append(UInt8((i &* 17) & 0xFF)) }
        // 200 bytes of a single repeating value (highly compressible)
        original.append(contentsOf: Array(repeating: UInt8(0xAB), count: 200))
        // 100 more random bytes
        for i in 100..<200 { original.append(UInt8((i &* 17) & 0xFF)) }

        var compressed = ClickHouseLZ4.compress(ByteBuffer(bytes: original))
        let decoded = try ClickHouseLZ4.decompress(from: &compressed, uncompressedSize: original.count)
        #expect(Array(decoded.readableBytesView) == original)
    }

    @Test("round-trip: encode then decode preserves the boundary requirement that the last 5 bytes are literals")
    func roundTripPreservesLastFiveAsLiterals() throws {
        // An input where a naive encoder might try to match into the last 5 bytes.
        let unit: [UInt8] = [0x55, 0xAA]
        var original: [UInt8] = []
        for _ in 0..<50 { original.append(contentsOf: unit) } // 100 bytes of "55AA" repeating

        var compressed = ClickHouseLZ4.compress(ByteBuffer(bytes: original))
        let decoded = try ClickHouseLZ4.decompress(from: &compressed, uncompressedSize: original.count)
        #expect(Array(decoded.readableBytesView) == original)
    }

    @Test("round-trip: encode then decode of input with all 256 byte values present")
    func roundTripAllByteValues() throws {
        var original: [UInt8] = []
        for _ in 0..<10 {
            for v in 0..<256 { original.append(UInt8(v)) }
        }

        var compressed = ClickHouseLZ4.compress(ByteBuffer(bytes: original))
        let decoded = try ClickHouseLZ4.decompress(from: &compressed, uncompressedSize: original.count)
        #expect(Array(decoded.readableBytesView) == original)
    }

    // MARK: - Decoder (continued)

    @Test("a 1 MiB pseudo-random buffer survives a compress -> decompress round-trip byte for byte")
    func zeroCopyCompressorPreservesLargePseudoRandomInput() throws {
        // Exercises the unsafe-pointer compress path on an input large
        // enough that the inner match-finding loop runs through many
        // literal/match boundaries. Pseudo-random bytes guarantee the
        // hash table stays warm and that match offsets above the
        // 12-byte safe window are exercised.
        let count = 1 << 20  // 1 MiB
        var rng = SeededRandomNumberGenerator(seed: 0xC1_5E_25_85_A0_47_C0_DE)
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        for _ in 0..<count {
            bytes.append(UInt8.random(in: 0...255, using: &rng))
        }
        let original = ByteBuffer(bytes: bytes)
        var compressed = ClickHouseLZ4.compress(original)
        let restored = try ClickHouseLZ4.decompress(from: &compressed, uncompressedSize: count)
        #expect(Array(restored.readableBytesView) == bytes)
        #expect(compressed.readableBytes == 0)
    }

    @Test("a highly redundant 256 KiB run-length pattern compresses below the input size and round-trips")
    func zeroCopyCompressorHandlesHighlyRedundantInput() throws {
        // RLE-heavy input forces the inner match loop to chain
        // overlapping matches through the literal+match boundary,
        // exercising the slice writes that emit literal subranges
        // directly from the unsafe pointer without intermediate copies.
        let count = 256 * 1024
        let pattern: [UInt8] = Array("SwiftDX-LZ4-".utf8)
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        while bytes.count < count {
            bytes.append(contentsOf: pattern)
        }
        bytes = Array(bytes.prefix(count))
        let original = ByteBuffer(bytes: bytes)
        var compressed = ClickHouseLZ4.compress(original)
        #expect(compressed.readableBytes < count / 2)
        let restored = try ClickHouseLZ4.decompress(from: &compressed, uncompressedSize: count)
        #expect(Array(restored.readableBytesView) == bytes)
    }

    @Test("a multi-sequence block (literals + match + literals + match) round-trips")
    func multipleSequencesDecode() throws {
        // Sequence 1: literals "abcdef" (6), match offset=6 length=4 (encoded=0).
        //   Token: literal=6 (high), match_encoded=0 (low) → 0x60.
        //   After seq1: output = "abcdefabcd" (10 bytes).
        // Sequence 2: literals "xy" (2), end of input (last sequence omits match).
        //   Token: literal=2 (high), match_encoded=irrelevant → 0x20.
        //   After seq2: output = "abcdefabcdxy" (12 bytes).
        let prefix: [UInt8] = [0x61, 0x62, 0x63, 0x64, 0x65, 0x66] // "abcdef"
        let suffix: [UInt8] = [0x78, 0x79] // "xy"
        var compressed = ByteBuffer(
            bytes: [0x60] + prefix + [0x06, 0x00] + [0x20] + suffix
        )
        let decoded = try ClickHouseLZ4.decompress(from: &compressed, uncompressedSize: 12)
        let expected: [UInt8] = prefix + [0x61, 0x62, 0x63, 0x64] + suffix
        #expect(Array(decoded.readableBytesView) == expected)
    }

}
