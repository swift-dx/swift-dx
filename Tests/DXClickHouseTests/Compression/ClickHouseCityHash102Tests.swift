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

// Golden vectors generated from `github.com/go-faster/city.CH128`,
// the exact CityHash102 implementation used by clickhouse/ch-go for
// compression-frame checksums. To regenerate, write a temporary Go
// program that imports `github.com/go-faster/city` and prints
// `city.CH128(input)` for each test input.
@Suite("ClickHouse CityHash102 (CH128 variant)")
struct ClickHouseCityHash102Tests {

    private static func hash(of bytes: [UInt8]) -> ClickHouseCityHash128 {
        let buffer = ByteBuffer(bytes: bytes)
        return ClickHouseCityHash102.hash128(buffer.readableBytesView)
    }

    @Test("empty input matches the canonical Go reference")
    func emptyInput() {
        let result = Self.hash(of: [])
        #expect(result == ClickHouseCityHash128(low: 0x3df0_9dfc_64c0_9a2b, high: 0x3cb5_40c3_92e5_1e29))
    }

    @Test("single zero byte matches the reference")
    func singleZeroByte() {
        let result = Self.hash(of: [0x00])
        #expect(result == ClickHouseCityHash128(low: 0xa04b_71ab_61de_6422, high: 0xf768_6849_37e2_3970))
    }

    @Test("single non-zero byte matches the reference")
    func singleNonZeroByte() {
        let result = Self.hash(of: [0x42])
        #expect(result == ClickHouseCityHash128(low: 0x46c1_3204_2e4a_16df, high: 0xf63f_00af_f7b3_ec37))
    }

    @Test("5-byte input \"Hello\" matches the reference (length 0..16 path)")
    func fiveByteInput() {
        let result = Self.hash(of: Array("Hello".utf8))
        #expect(result == ClickHouseCityHash128(low: 0x7ed0_b682_0411_d331, high: 0xa9e7_c57c_ea9b_3d08))
    }

    @Test("13-byte input matches the reference (length 8..16 path)")
    func thirteenByteInput() {
        let result = Self.hash(of: Array("Hello, World!".utf8))
        #expect(result == ClickHouseCityHash128(low: 0x703d_abf8_d081_ec00, high: 0xa196_e28f_28c3_ee09))
    }

    @Test("16-byte ascending input matches the reference (length-16 boundary)")
    func sixteenByteInput() {
        let result = Self.hash(of: [
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
            0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f
        ])
        #expect(result == ClickHouseCityHash128(low: 0x17ce_ade6_77c2_f945, high: 0x579e_d606_75c8_fedc))
    }

    @Test("32-byte ascending input matches the reference (16..127 cityMurmur path)")
    func thirtyTwoByteInput() {
        let result = Self.hash(of: [
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
            0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
            0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
            0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f
        ])
        #expect(result == ClickHouseCityHash128(low: 0xfe71_590c_670b_561d, high: 0x498f_5b46_4f87_5a30))
    }

    @Test("64-byte repeating input matches the reference (cityMurmur multi-iteration path)")
    func sixtyFourByteRepeating() {
        let result = Self.hash(of: Array(repeating: UInt8(0x61), count: 64))
        #expect(result == ClickHouseCityHash128(low: 0x5a8d_90d5_abee_90a9, high: 0x9674_e5c6_64aa_d540))
    }

    @Test("127-byte repeating input — last length before the >=128 main-loop path")
    func oneTwentySevenByte() {
        let result = Self.hash(of: Array(repeating: UInt8(0x62), count: 127))
        #expect(result == ClickHouseCityHash128(low: 0x3965_436e_6f34_6905, high: 0x5163_739a_9615_6a36))
    }

    @Test("128-byte repeating input — first length where post-skip = 112 still hits cityMurmur")
    func oneTwentyEightByte() {
        let result = Self.hash(of: Array(repeating: UInt8(0x63), count: 128))
        #expect(result == ClickHouseCityHash128(low: 0xa79d_4b70_9e5b_d337, high: 0x9cb8_dccf_729f_8a4a))
    }

    @Test("256-byte repeating input — exercises the main loop and the trailing 32-byte handler")
    func twoFiftySixByteInput() {
        let result = Self.hash(of: Array(repeating: UInt8(0x64), count: 256))
        #expect(result == ClickHouseCityHash128(low: 0x762d_abb2_fb95_ea17, high: 0x240f_bf40_d09b_4cef))
    }

    @Test("1024-byte repeating input — exercises many main-loop iterations")
    func oneThousandTwentyFourByteInput() {
        let result = Self.hash(of: Array(repeating: UInt8(0x65), count: 1024))
        #expect(result == ClickHouseCityHash128(low: 0x1adf_952d_9f8a_6684, high: 0x2e0f_715d_1a10_14c4))
    }

    @Test("a realistic ClickHouse compression frame body matches the reference")
    func compressionFrameBodyExample() {
        // Layout: [method=0x82 (LZ4), compressed_size LE=16, uncompressed_size LE=5, payload "Hello"]
        // This is the byte range that CityHash128 is computed over for an LZ4-compressed
        // 5-byte payload, exactly as the wire format demands.
        let result = Self.hash(of: [
            0x82, 0x10, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00,
            0x50, 0x48, 0x65, 0x6c, 0x6c, 0x6f
        ])
        #expect(result == ClickHouseCityHash128(low: 0x64f0_d5f8_5fc6_a5ec, high: 0x83eb_13c9_98ee_b95a))
    }

    @Test("hashing is deterministic — the same input produces the same output across calls")
    func determinism() {
        let input = Array("the quick brown fox jumps over the lazy dog".utf8)
        let first = Self.hash(of: input)
        let second = Self.hash(of: input)
        #expect(first == second)
    }

    @Test("flipping a single bit produces a completely different hash (avalanche)")
    func avalancheOnSingleBitFlip() {
        var input = Array(repeating: UInt8(0xAA), count: 64)
        let baseline = Self.hash(of: input)
        input[31] ^= 0x01
        let flipped = Self.hash(of: input)
        #expect(baseline != flipped)
        #expect(baseline.low != flipped.low)
        #expect(baseline.high != flipped.high)
    }

}
