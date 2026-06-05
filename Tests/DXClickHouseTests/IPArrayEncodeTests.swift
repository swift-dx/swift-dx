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
import Testing

// Array(IPv4) / Array(IPv6) decode natively into [ClickHouseIPv4] /
// [ClickHouseIPv6], but inserting them was impossible: the raw-bytes
// FixedString shape produced the wrong column type. First-class IPv4 / IPv6
// element types make these address arrays insert symmetrically with select.
@Suite("[ClickHouseIPv4/IPv6] arrays insert symmetrically with how they select")
struct IPArrayEncodeTests {

    private struct V4Row: Codable, Sendable, Equatable { let hops: [ClickHouseIPv4] }
    private struct V6Row: Codable, Sendable, Equatable { let hops: [ClickHouseIPv6] }

    @Test("a [ClickHouseIPv4] field round-trips through encode then decode")
    func ipv4RoundTrips() throws {
        let original = [V4Row(hops: [ClickHouseIPv4(raw: 0x0102_0304), ClickHouseIPv4(raw: 0x0506_0708)])]
        let columns = try ClickHouseRowEncoder().encode(original)
        #expect(columns[0].column.typeName == "Array(IPv4)")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: V4Row.self, columns: columns, rowCount: 1)
        #expect(decoded == original)
    }

    @Test("an empty [ClickHouseIPv4] encodes as an empty Array(IPv4)")
    func ipv4Empty() throws {
        let original = [V4Row(hops: [])]
        let columns = try ClickHouseRowEncoder().encode(original)
        #expect(columns[0].column.typeName == "Array(IPv4)")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: V4Row.self, columns: columns, rowCount: 1)
        #expect(decoded == original)
    }

    @Test("a [ClickHouseIPv6] field round-trips through encode then decode")
    func ipv6RoundTrips() throws {
        let a = (0..<16).map { UInt8($0) }
        let b = (16..<32).map { UInt8($0) }
        let original = [V6Row(hops: [ClickHouseIPv6(bytes: a), ClickHouseIPv6(bytes: b)])]
        let columns = try ClickHouseRowEncoder().encode(original)
        #expect(columns[0].column.typeName == "Array(IPv6)")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: V6Row.self, columns: columns, rowCount: 1)
        #expect(decoded == original)
    }
}
