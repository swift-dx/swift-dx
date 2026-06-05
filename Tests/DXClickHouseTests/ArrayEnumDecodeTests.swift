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

// Array(Enum8(...)) / Array(Enum16(...)) carry sequences of categorical
// values (a row's set of statuses, tags, or categories). On the wire each
// element is the enum's signed ordinal (1 byte for Enum8, 2 for Enum16),
// with the name mapping declared in the column type. The decoder rejected
// the Enum element types, failing the whole select. These decode into
// [ClickHouseEnum8] / [ClickHouseEnum16], preserving the ordinal and the
// column's name mapping.
@Suite("DXClickHouse Array(Enum8) / Array(Enum16) decode")
struct ArrayEnumDecodeTests {

    struct Enum8Row: Codable, Sendable, Equatable { let states: [ClickHouseEnum8] }
    struct Enum16Row: Codable, Sendable, Equatable { let codes: [ClickHouseEnum16] }

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func int16LE(_ value: Int16) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    @Test("Array(Enum8) decodes ordinals against the column's mapping")
    func decodesArrayOfEnum8() throws {
        let mapping = [ClickHouseEnumPair(name: "active", value: 1), ClickHouseEnumPair(name: "closed", value: 2)]
        let body = Self.uint64LE(2) + [0x01, 0x02]
        let block = ClickHouseBlock(
            rowCount: 1, columnCount: 1,
            columnNames: ["states"],
            columnTypes: ["Array(Enum8('active' = 1, 'closed' = 2))"],
            bodyStart: 0, bodyLength: body.count
        )
        let columns = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Enum8Row.self, columns: columns, rowCount: 1)
        #expect(rows == [Enum8Row(states: [
            ClickHouseEnum8(value: 1, mapping: mapping),
            ClickHouseEnum8(value: 2, mapping: mapping),
        ])])
    }

    @Test("Array(Enum16) decodes 2-byte ordinals against the column's mapping")
    func decodesArrayOfEnum16() throws {
        let mapping = [ClickHouseEnumPair(name: "a", value: 100), ClickHouseEnumPair(name: "b", value: 200)]
        let body = Self.uint64LE(2) + Self.int16LE(100) + Self.int16LE(200)
        let block = ClickHouseBlock(
            rowCount: 1, columnCount: 1,
            columnNames: ["codes"],
            columnTypes: ["Array(Enum16('a' = 100, 'b' = 200))"],
            bodyStart: 0, bodyLength: body.count
        )
        let columns = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Enum16Row.self, columns: columns, rowCount: 1)
        #expect(rows == [Enum16Row(codes: [
            ClickHouseEnum16(value: 100, mapping: mapping),
            ClickHouseEnum16(value: 200, mapping: mapping),
        ])])
    }
}
