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

@Suite("ClickHouse BFloat16")
struct ClickHouseBFloat16Tests {

    // MARK: - Value type

    @Test("zero round-trips bit-exact through Float and back")
    func zeroRoundTrip() {
        let bf = ClickHouseBFloat16.zero
        #expect(bf.rawBits == 0)
        #expect(bf.floatValue == 0.0)
        #expect(ClickHouseBFloat16(0.0 as Float).rawBits == 0)
    }

    @Test("Float32 1.0 truncates to BFloat16 1.0 with no precision loss (mantissa fits in 7 bits)")
    func oneFloatRoundTrip() {
        let bf = ClickHouseBFloat16(Float(1.0))
        #expect(bf.floatValue == 1.0)
    }

    @Test("Float32 -1.0 → BFloat16 → Float32 preserves the sign")
    func negativeFloatRoundTrip() {
        let bf = ClickHouseBFloat16(Float(-1.0))
        #expect(bf.floatValue == -1.0)
    }

    @Test("Float32 with mantissa fitting in 7 bits round-trips bit-exact")
    func smallExactFloatRoundTrip() {
        // 1.5 has mantissa = 1.1 binary, which fits in BFloat16's 7-bit mantissa.
        let exactValues: [Float] = [0.5, 1.5, 2.0, -2.5, 0.125, 256.0]
        for value in exactValues {
            let bf = ClickHouseBFloat16(value)
            #expect(bf.floatValue == value, "\(value) should round-trip exactly")
        }
    }

    @Test("Float32 with full 23-bit mantissa truncates lower bits in BFloat16")
    func longMantissaTruncates() {
        // pi has mantissa requiring more than 7 bits — BFloat16 truncates.
        let pi = Float.pi
        let bf = ClickHouseBFloat16(pi)
        let recovered = bf.floatValue
        // The recovered value should be CLOSE to pi but not equal.
        #expect(recovered != pi, "BFloat16 should truncate Float32.pi's lower mantissa bits")
        #expect(abs(recovered - pi) < 0.02, "BFloat16 of pi should be within 2% of pi")
    }

    @Test("Float32 infinity preserves through BFloat16")
    func infinityPreserved() {
        let positiveInf = ClickHouseBFloat16(Float.infinity)
        let negativeInf = ClickHouseBFloat16(-Float.infinity)
        #expect(positiveInf.floatValue == Float.infinity)
        #expect(negativeInf.floatValue == -Float.infinity)
    }

    @Test("Float32 NaN preserves NaN-ness through BFloat16")
    func nanPreserved() {
        let nan = ClickHouseBFloat16(Float.nan)
        #expect(nan.floatValue.isNaN)
    }

    @Test("rawBits round-trip via init(rawBits:) preserves the exact bit pattern")
    func rawBitsRoundTrip() {
        let patterns: [UInt16] = [0x0000, 0x3F80, 0xBF80, 0x4000, 0x7F80, 0xFF80, 0x7FC0]
        for bits in patterns {
            let bf = ClickHouseBFloat16(rawBits: bits)
            #expect(bf.rawBits == bits)
        }
    }

    // MARK: - Spec + parser

    @Test("BFloat16 typeName + parser round-trip")
    func typeNameRoundTrip() throws {
        #expect(ClickHouseColumnSpec.bfloat16.typeName == "BFloat16")
        #expect(try ClickHouseTypeNameParser.parse("BFloat16") == .bfloat16)
    }

    // MARK: - Wire format

    @Test("BFloat16 column encodes 2 bytes per row in little-endian order")
    func wireFormatIs2BytesLE() {
        let bf = ClickHouseBFloat16(rawBits: 0x3F80) // = Float 1.0 in BFloat16
        let column = ClickHouseBFloat16Column(spec: .bfloat16, values: [bf])
        var buffer = ByteBuffer()
        column.encode(into: &buffer)
        #expect(buffer.readableBytes == 2)
        let bytes = buffer.getBytes(at: 0, length: 2) ?? []
        #expect(bytes[0] == 0x80, "low byte first (little-endian)")
        #expect(bytes[1] == 0x3F, "high byte second")
    }

    @Test("BFloat16 column round-trips boundary values via the registry")
    func wireRoundTrip() throws {
        let original: [ClickHouseBFloat16] = [
            .zero,
            ClickHouseBFloat16(Float(1.0)),
            ClickHouseBFloat16(Float(-1.0)),
            ClickHouseBFloat16(Float(256.0)),
            ClickHouseBFloat16(Float.infinity),
            ClickHouseBFloat16(rawBits: 0xFFFF)  // arbitrary bit pattern (NaN-ish)
        ]
        let column = ClickHouseBFloat16Column(spec: .bfloat16, values: original)
        var buffer = ByteBuffer()
        column.encode(into: &buffer)
        #expect(buffer.readableBytes == original.count * 2)

        let decoded = try ClickHouseColumnRegistry.decode(spec: .bfloat16, rows: original.count, from: &buffer)
        let typed = try #require(decoded as? ClickHouseBFloat16Column)
        #expect(typed.values == original)
        #expect(buffer.readableBytes == 0)
    }

    @Test("decoding from a truncated buffer (less than 2 bytes per row) throws")
    func truncatedBufferThrows() {
        var buffer = ByteBuffer()
        buffer.writeBytes([0x80]) // 1 byte short
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseBFloat16Column.decode(spec: .bfloat16, rows: 1, from: &buffer)
        }
    }

    // MARK: - Public API

    @Test("public typed-INSERT API converts .bfloat16 to a ClickHouseBFloat16Column with .bfloat16 spec")
    func publicAPIConvertsBFloat16() throws {
        let values: [ClickHouseBFloat16] = [
            ClickHouseBFloat16(Float(1.5)),
            ClickHouseBFloat16(Float(-2.0)),
            .zero
        ]
        let column = try ClickHouseClient.toInternalColumn(.bfloat16(values))
        let typed = try #require(column as? ClickHouseBFloat16Column)
        #expect(typed.values == values)
        #expect(typed.spec == .bfloat16)
    }

    @Test("an empty .bfloat16([]) produces a 0-row column")
    func emptyBFloat16Column() throws {
        let column = try ClickHouseClient.toInternalColumn(.bfloat16([]))
        let typed = try #require(column as? ClickHouseBFloat16Column)
        #expect(typed.values.isEmpty)
    }

}
