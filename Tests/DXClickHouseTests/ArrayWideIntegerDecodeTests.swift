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

import DXClickHouse
import Foundation
import Testing

// Array(Int128/UInt128/Int256/UInt256) carry the wide integers ClickHouse
// uses for large identifiers, hashes, and high-precision amounts. On the
// wire each is the same offsets-then-flattened layout as a fixed-width
// element array: 16 little-endian bytes for the 128-bit widths, 32 for the
// 256-bit widths (four little-endian 8-byte limbs, least significant first).
// The decoder rejected these element types, failing the whole select.
@Suite("DXClickHouse Array(Int128/UInt128/Int256/UInt256) decode")
struct ArrayWideIntegerDecodeTests {

    struct Int128Row: Codable, Sendable, Equatable { let values: [ClickHouseInt128] }
    struct UInt128Row: Codable, Sendable, Equatable { let values: [ClickHouseUInt128] }
    struct Int256Row: Codable, Sendable, Equatable { let values: [ClickHouseInt256] }
    struct UInt256Row: Codable, Sendable, Equatable { let values: [ClickHouseUInt256] }

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func int128LE(_ value: Int128) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func uint128LE(_ value: UInt128) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func decode<T: Decodable & Sendable>(_ type: T.Type, columnType: String, body: [UInt8]) throws -> [T] {
        let block = ClickHouseBlock(
            rowCount: 1, columnCount: 1,
            columnNames: ["values"],
            columnTypes: [columnType],
            bodyStart: 0, bodyLength: body.count
        )
        let columns = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        return try ClickHouseCodableDecoder.decodeRows(type: type, columns: columns, rowCount: 1)
    }

    @Test("Array(Int128) decodes positive and negative 16-byte values")
    func decodesArrayOfInt128() throws {
        let body = Self.uint64LE(2) + Self.int128LE(Int128(100)) + Self.int128LE(Int128(-5))
        let rows = try Self.decode(Int128Row.self, columnType: "Array(Int128)", body: body)
        #expect(rows == [Int128Row(values: [ClickHouseInt128(Int128(100)), ClickHouseInt128(Int128(-5))])])
    }

    @Test("Array(UInt128) decodes 16-byte values")
    func decodesArrayOfUInt128() throws {
        let body = Self.uint64LE(2) + Self.uint128LE(UInt128(1)) + Self.uint128LE(UInt128(0xFFFF_FFFF_FFFF_FFFF))
        let rows = try Self.decode(UInt128Row.self, columnType: "Array(UInt128)", body: body)
        #expect(rows == [UInt128Row(values: [ClickHouseUInt128(UInt128(1)), ClickHouseUInt128(UInt128(0xFFFF_FFFF_FFFF_FFFF))])])
    }

    @Test("Array(Int256) decodes 32-byte four-limb values")
    func decodesArrayOfInt256() throws {
        let element = Self.uint64LE(1) + Self.uint64LE(2) + Self.uint64LE(3) + Self.uint64LE(4)
        let body = Self.uint64LE(1) + element
        let rows = try Self.decode(Int256Row.self, columnType: "Array(Int256)", body: body)
        #expect(rows == [Int256Row(values: [ClickHouseInt256(limb0: 1, limb1: 2, limb2: 3, limb3: 4)])])
    }

    @Test("Array(UInt256) decodes 32-byte four-limb values")
    func decodesArrayOfUInt256() throws {
        let element = Self.uint64LE(5) + Self.uint64LE(6) + Self.uint64LE(7) + Self.uint64LE(8)
        let body = Self.uint64LE(1) + element
        let rows = try Self.decode(UInt256Row.self, columnType: "Array(UInt256)", body: body)
        #expect(rows == [UInt256Row(values: [ClickHouseUInt256(limb0: 5, limb1: 6, limb2: 7, limb3: 8)])])
    }
}
