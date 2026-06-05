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

// Array(IPv4) and Array(IPv6) are common in analytics, security, and logging
// schemas (a row's set of addresses). On the wire they are laid out like
// Array(FixedString(4)) and Array(FixedString(16)): cumulative per-row
// offsets followed by the flattened fixed-width elements. IPv4 is a 4-byte
// little-endian integer; IPv6 is 16 network-order bytes. The decoder
// rejected both element types, failing the whole select.
@Suite("DXClickHouse Array(IPv4) / Array(IPv6) decode")
struct ArrayIPAddressDecodeTests {

    struct V4Row: Codable, Sendable, Equatable { let hops: [ClickHouseIPv4] }
    struct V6Row: Codable, Sendable, Equatable { let hops: [ClickHouseIPv6] }

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func uint32LE(_ value: UInt32) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    @Test("Array(IPv4) decodes each element as a little-endian raw integer")
    func decodesArrayOfIPv4() throws {
        let body = Self.uint64LE(2) + Self.uint32LE(0x0102_0304) + Self.uint32LE(0x0506_0708)
        let block = ClickHouseBlock(
            rowCount: 1, columnCount: 1,
            columnNames: ["hops"],
            columnTypes: ["Array(IPv4)"],
            bodyStart: 0, bodyLength: body.count
        )
        let columns = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        let rows = try ClickHouseCodableDecoder.decodeRows(type: V4Row.self, columns: columns, rowCount: 1)
        #expect(rows == [V4Row(hops: [ClickHouseIPv4(raw: 0x0102_0304), ClickHouseIPv4(raw: 0x0506_0708)])])
    }

    @Test("Array(IPv6) decodes each element as its 16 network-order bytes")
    func decodesArrayOfIPv6() throws {
        let aBytes: [UInt8] = (0..<16).map { UInt8($0) }
        let bBytes: [UInt8] = (16..<32).map { UInt8($0) }
        let body = Self.uint64LE(2) + aBytes + bBytes
        let block = ClickHouseBlock(
            rowCount: 1, columnCount: 1,
            columnNames: ["hops"],
            columnTypes: ["Array(IPv6)"],
            bodyStart: 0, bodyLength: body.count
        )
        let columns = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        let rows = try ClickHouseCodableDecoder.decodeRows(type: V6Row.self, columns: columns, rowCount: 1)
        #expect(rows == [V6Row(hops: [ClickHouseIPv6(bytes: aBytes), ClickHouseIPv6(bytes: bBytes)])])
    }
}
