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
import Testing

// Array(Nullable(T)) is now symmetric: a [T?] field both decodes (iter prior)
// and encodes. The wire body is rowCount cumulative offsets, then the inner
// Nullable(T) column — a totalElements null mask followed by totalElements
// values (a NULL slot carries the type placeholder). This pins the exact
// encoded bytes for the variable-width String case and round-trips both a
// variable-width (String) and a fixed-width (Int64) element type.
@Suite("Array(Nullable(T)) encodes symmetrically and round-trips")
struct ArrayOfNullableEncodeTests {

    private struct StringRow: Codable, Sendable, Equatable { let v: [String?] }
    private struct IntRow: Codable, Sendable, Equatable { let v: [Int64?] }

    @Test("a [String?] column encodes to the exact Array(Nullable(String)) wire body")
    func encodesExactWireBody() throws {
        let columns = try ClickHouseRowEncoder().encode([StringRow(v: ["a", nil])])
        #expect(columns[0].column.typeName == "Array(Nullable(String))")
        let packet = try ClickHouseBlockWriter.encodeDataPacket(
            columns: columns,
            revision: ClickHouseBlockWriter.revisionWithCustomSerialization
        )
        // offset uint64LE(2); mask 0,1; value "a" (len 1 + 'a'); placeholder "" (len 0).
        let expectedBody: [UInt8] = [
            0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // offsets [2]
            0x00, 0x01,                                       // null mask: present, NULL
            0x01, 0x61,                                       // "a"
            0x00,                                             // "" placeholder for the NULL
        ]
        #expect(Array(packet.suffix(expectedBody.count)) == expectedBody)
    }

    @Test("a [String?] batch round-trips through encode then decode")
    func stringRoundTrips() throws {
        let rows = [StringRow(v: ["a", nil, "c"]), StringRow(v: []), StringRow(v: [nil, nil])]
        let columns = try ClickHouseRowEncoder().encode(rows)
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: StringRow.self, columns: columns, rowCount: rows.count)
        #expect(decoded == rows)
    }

    @Test("an [Int64?] batch round-trips through encode then decode")
    func int64RoundTrips() throws {
        let rows = [IntRow(v: [10, nil, 30]), IntRow(v: [nil]), IntRow(v: [])]
        let columns = try ClickHouseRowEncoder().encode(rows)
        #expect(columns[0].column.typeName == "Array(Nullable(Int64))")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: IntRow.self, columns: columns, rowCount: rows.count)
        #expect(decoded == rows)
    }
}
