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
import Foundation
import Testing

// Array(Nullable(T)) extends to the fixed-conversion value-wrapper element
// types (UUID, IPv4/IPv6, the 128/256-bit integers), matching the coverage of
// the non-nullable [T] arrays. Each round-trips through encode then decode
// with NULL elements interspersed.
@Suite("Array(Nullable(value-wrapper)) round-trips")
struct ArrayOfNullableWrapperTests {

    private struct UUIDRow: Codable, Sendable, Equatable { let v: [UUID?] }
    private struct Int128Row: Codable, Sendable, Equatable { let v: [ClickHouseInt128?] }
    private struct IPv4Row: Codable, Sendable, Equatable { let v: [ClickHouseIPv4?] }

    @Test("a [UUID?] batch round-trips with interspersed NULLs")
    func uuidRoundTrips() throws {
        let a = UUID(uuid: (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15))
        let b = UUID(uuid: (16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31))
        let rows = [UUIDRow(v: [a, nil, b]), UUIDRow(v: []), UUIDRow(v: [nil])]
        let columns = try ClickHouseRowEncoder().encode(rows)
        #expect(columns[0].column.typeName == "Array(Nullable(UUID))")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: UUIDRow.self, columns: columns, rowCount: rows.count)
        #expect(decoded == rows)
    }

    @Test("an [ClickHouseInt128?] batch round-trips with interspersed NULLs")
    func int128RoundTrips() throws {
        let rows = [Int128Row(v: [ClickHouseInt128(42), nil, ClickHouseInt128(-7)]), Int128Row(v: [nil, nil])]
        let columns = try ClickHouseRowEncoder().encode(rows)
        #expect(columns[0].column.typeName == "Array(Nullable(Int128))")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Int128Row.self, columns: columns, rowCount: rows.count)
        #expect(decoded == rows)
    }

    @Test("a [ClickHouseIPv4?] batch round-trips with interspersed NULLs")
    func ipv4RoundTrips() throws {
        let rows = [IPv4Row(v: [ClickHouseIPv4(raw: 0x7F00_0001), nil, ClickHouseIPv4(raw: 0x0A00_0001)])]
        let columns = try ClickHouseRowEncoder().encode(rows)
        #expect(columns[0].column.typeName == "Array(Nullable(IPv4))")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: IPv4Row.self, columns: columns, rowCount: rows.count)
        #expect(decoded == rows)
    }
}
