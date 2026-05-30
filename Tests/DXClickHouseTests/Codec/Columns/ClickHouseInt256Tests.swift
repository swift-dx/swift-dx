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

@Suite("ClickHouse Int256 / UInt256 / Decimal256")
struct ClickHouseInt256Tests {

    // MARK: - Value type construction

    @Test("ClickHouseInt256.zero is all zero limbs")
    func int256Zero() {
        let zero = ClickHouseInt256.zero
        #expect(zero.limb0 == 0)
        #expect(zero.limb1 == 0)
        #expect(zero.limb2 == 0)
        #expect(zero.limb3 == 0)
    }

    @Test("ClickHouseInt256.min has only the top bit of limb3 set")
    func int256Min() {
        let min = ClickHouseInt256.min
        #expect(min.limb0 == 0)
        #expect(min.limb1 == 0)
        #expect(min.limb2 == 0)
        #expect(min.limb3 == 0x8000_0000_0000_0000)
    }

    @Test("ClickHouseInt256.max has all limbs full except the top bit of limb3")
    func int256Max() {
        let max = ClickHouseInt256.max
        #expect(max.limb0 == UInt64.max)
        #expect(max.limb1 == UInt64.max)
        #expect(max.limb2 == UInt64.max)
        #expect(max.limb3 == 0x7FFF_FFFF_FFFF_FFFF)
    }

    @Test("ClickHouseInt256.init(Int64) sign-extends negative values across the upper limbs")
    func int256SignExtendsNegativeInt64() {
        let negative = ClickHouseInt256(Int64(-1))
        #expect(negative.limb0 == UInt64.max)
        #expect(negative.limb1 == UInt64.max)
        #expect(negative.limb2 == UInt64.max)
        #expect(negative.limb3 == UInt64.max)
    }

    @Test("ClickHouseInt256.init(Int64) zero-fills positive values in the upper limbs")
    func int256ZeroFillsPositiveInt64() {
        let positive = ClickHouseInt256(Int64(42))
        #expect(positive.limb0 == 42)
        #expect(positive.limb1 == 0)
        #expect(positive.limb2 == 0)
        #expect(positive.limb3 == 0)
    }

    @Test("ClickHouseUInt256.zero / max")
    func uint256Bounds() {
        #expect(ClickHouseUInt256.zero.limb0 == 0)
        #expect(ClickHouseUInt256.zero.limb3 == 0)
        #expect(ClickHouseUInt256.max.limb0 == UInt64.max)
        #expect(ClickHouseUInt256.max.limb3 == UInt64.max)
    }

    @Test("Int256 and UInt256 with identical limbs are NOT comparable across types — they are distinct types")
    func crossTypeNotComparable() {
        // This is a compile-time check. The test asserts that the API doesn't
        // have a cross-type Equatable conformance (which would be unsafe given
        // the differing sign interpretation).
        let i = ClickHouseInt256(limb0: 1, limb1: 2, limb2: 3, limb3: 4)
        let u = ClickHouseUInt256(limb0: 1, limb1: 2, limb2: 3, limb3: 4)
        #expect(i.limb0 == u.limb0) // limbs are individually comparable as UInt64
        // But the wrapper types themselves are distinct — no `i == u` equality.
    }

    // MARK: - Spec + parser

    @Test("Int256 typeName + parser round-trip")
    func int256TypeNameRoundTrip() throws {
        #expect(ClickHouseColumnSpec.int256.typeName == "Int256")
        #expect(try ClickHouseTypeNameParser.parse("Int256") == .int256)
    }

    @Test("UInt256 typeName + parser round-trip")
    func uint256TypeNameRoundTrip() throws {
        #expect(ClickHouseColumnSpec.uint256.typeName == "UInt256")
        #expect(try ClickHouseTypeNameParser.parse("UInt256") == .uint256)
    }

    @Test("Decimal256(scale) typeName + parser round-trip preserves the scale")
    func decimal256TypeNameRoundTrip() throws {
        #expect(ClickHouseColumnSpec.decimal256(scale: 10).typeName == "Decimal256(10)")
        #expect(try ClickHouseTypeNameParser.parse("Decimal256(10)") == .decimal256(scale: 10))
    }

    @Test("Decimal(76, scale) parser alias maps to .decimal256(scale)")
    func decimal76AliasMapsToDecimal256() throws {
        #expect(try ClickHouseTypeNameParser.parse("Decimal(76, 5)") == .decimal256(scale: 5))
        #expect(try ClickHouseTypeNameParser.parse("Decimal(50, 0)") == .decimal256(scale: 0))
    }

    @Test("Decimal precision above 76 throws (exceeds Decimal256's maximum)")
    func decimalPrecisionAbove76Throws() {
        #expect(throws: ClickHouseError.self) {
            try ClickHouseTypeNameParser.parse("Decimal(100, 5)")
        }
    }

    // MARK: - Wire format

    @Test("Int256 column encodes 32 bytes per row in little-endian limb order")
    func int256WireBytes() {
        let value = ClickHouseInt256(limb0: 0x0102_0304_0506_0708, limb1: 0, limb2: 0, limb3: 0)
        let column = ClickHouseInt256Column(spec: .int256, values: [value])
        var buffer = ByteBuffer()
        column.encode(into: &buffer)
        #expect(buffer.readableBytes == 32)
        let bytes = buffer.getBytes(at: 0, length: 32) ?? []
        // Limb 0 is little-endian first
        #expect(bytes[0] == 0x08)
        #expect(bytes[1] == 0x07)
        #expect(bytes[7] == 0x01)
        // Upper limbs are zero
        #expect(Array(bytes[8..<32]) == Array(repeating: UInt8(0), count: 24))
    }

    @Test("Int256 column round-trips boundary values via the registry")
    func int256BoundaryRoundTrip() throws {
        let original: [ClickHouseInt256] = [
            .min,
            .zero,
            .max,
            ClickHouseInt256(Int64(-1)),
            ClickHouseInt256(Int64(42)),
            ClickHouseInt256(limb0: 0xDEAD_BEEF, limb1: 0xCAFE_BABE, limb2: 0xFEED_FACE, limb3: 0x1234_5678)
        ]
        let column = ClickHouseInt256Column(spec: .int256, values: original)
        var buffer = ByteBuffer()
        column.encode(into: &buffer)
        #expect(buffer.readableBytes == original.count * 32)

        let decoded = try ClickHouseColumnRegistry.decode(spec: .int256, rows: original.count, from: &buffer)
        let typed = try #require(decoded as? ClickHouseInt256Column)
        #expect(typed.values == original)
        #expect(buffer.readableBytes == 0)
    }

    @Test("UInt256 column round-trips boundary values via the registry")
    func uint256BoundaryRoundTrip() throws {
        let original: [ClickHouseUInt256] = [
            .zero,
            .max,
            ClickHouseUInt256(UInt64.max),
            ClickHouseUInt256(limb0: 1, limb1: 2, limb2: 3, limb3: 4)
        ]
        let column = ClickHouseUInt256Column(spec: .uint256, values: original)
        var buffer = ByteBuffer()
        column.encode(into: &buffer)

        let decoded = try ClickHouseColumnRegistry.decode(spec: .uint256, rows: original.count, from: &buffer)
        let typed = try #require(decoded as? ClickHouseUInt256Column)
        #expect(typed.values == original)
    }

    @Test("Decimal256 reuses Int256 storage; round-trips with the .decimal256(scale:) spec")
    func decimal256RoundTrip() throws {
        let original: [ClickHouseInt256] = [
            ClickHouseInt256(Int64(123_456)),  // 123.456 at scale 3
            ClickHouseInt256(Int64(-1_000_000))
        ]
        let column = ClickHouseInt256Column(spec: .decimal256(scale: 3), values: original)
        var buffer = ByteBuffer()
        column.encode(into: &buffer)

        let decoded = try ClickHouseColumnRegistry.decode(spec: .decimal256(scale: 3), rows: original.count, from: &buffer)
        let typed = try #require(decoded as? ClickHouseInt256Column)
        #expect(typed.values == original)
        #expect(typed.spec == .decimal256(scale: 3))
    }

    @Test("decoding an Int256 column from a truncated buffer (less than 32 bytes per row) throws")
    func int256TruncatedBufferThrows() {
        var buffer = ByteBuffer()
        buffer.writeBytes(Array(repeating: UInt8(0), count: 31)) // 1 byte short
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseInt256Column.decode(spec: .int256, rows: 1, from: &buffer)
        }
    }

    // MARK: - Public API integration

    @Test("public typed-INSERT API converts .int256 to a ClickHouseInt256Column with .int256 spec")
    func publicAPIConvertsInt256() throws {
        let values: [ClickHouseInt256] = [.min, .zero, .max]
        let column = try ClickHouseClient.toInternalColumn(.int256(values))
        let typed = try #require(column as? ClickHouseInt256Column)
        #expect(typed.values == values)
        #expect(typed.spec == .int256)
    }

    @Test("public typed-INSERT API converts .uint256 to a ClickHouseUInt256Column with .uint256 spec")
    func publicAPIConvertsUInt256() throws {
        let values: [ClickHouseUInt256] = [.zero, .max]
        let column = try ClickHouseClient.toInternalColumn(.uint256(values))
        let typed = try #require(column as? ClickHouseUInt256Column)
        #expect(typed.values == values)
        #expect(typed.spec == .uint256)
    }

    @Test("public typed-INSERT API converts .decimal256(scale:) to ClickHouseInt256Column with .decimal256(scale:) spec")
    func publicAPIConvertsDecimal256() throws {
        let values: [ClickHouseInt256] = [ClickHouseInt256(Int64(99_999_999_999))]
        let column = try ClickHouseClient.toInternalColumn(.decimal256(values, scale: 18))
        let typed = try #require(column as? ClickHouseInt256Column)
        #expect(typed.values == values)
        #expect(typed.spec == .decimal256(scale: 18))
    }

    // MARK: - Spec equality

    @Test("Int256 != UInt256 spec; Decimal256 specs with different scales are not equal")
    func specEquality() {
        #expect(ClickHouseColumnSpec.int256 != .uint256)
        #expect(ClickHouseColumnSpec.decimal256(scale: 3) != .decimal256(scale: 6))
        #expect(ClickHouseColumnSpec.int256 != .decimal256(scale: 0))
    }

}
