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

// A batch INSERT whose first row carries nil in an Optional wrapper field
// must still register the column. For fixed-width and fixed-numeric
// wrappers (IPv4, IPv6, Date32, Date, Time, BFloat16, Int128/UInt128,
// Int256/UInt256) the ClickHouse type is fully determined by the Swift
// type, so a leading nil should not force the caller to reorder rows so a
// non-null value comes first. Previously the encoder rejected this with
// "column is NULL on its first encoded row".
@Suite("A first-row nil fixed-shape wrapper still registers the Nullable column")
struct FirstRowNullWrapperTests {

    private struct IPv4Row: Codable, Sendable, Equatable {
        let addr: ClickHouseIPv4?
    }

    private struct Int128Row: Codable, Sendable, Equatable {
        let big: ClickHouseInt128?
    }

    @Test("a leading nil IPv4 encodes as a Nullable(IPv4) column")
    func leadingNilIPv4Encodes() throws {
        let columns = try ClickHouseRowEncoder().encode([
            IPv4Row(addr: nil),
            IPv4Row(addr: ClickHouseIPv4(raw: 0x7F00_0001)),
        ])
        #expect(columns[0].column.typeName == "Nullable(IPv4)")
        #expect(columns[0].column.rowCount == 2)
    }

    @Test("a leading nil Int128 encodes as a Nullable(Int128) column")
    func leadingNilInt128Encodes() throws {
        let columns = try ClickHouseRowEncoder().encode([
            Int128Row(big: nil),
            Int128Row(big: ClickHouseInt128(42)),
        ])
        #expect(columns[0].column.typeName == "Nullable(Int128)")
        #expect(columns[0].column.rowCount == 2)
    }

    @Test("a leading-nil IPv4 batch round-trips through encode and decode")
    func leadingNilIPv4RoundTrips() throws {
        let rows = [
            IPv4Row(addr: nil),
            IPv4Row(addr: ClickHouseIPv4(raw: 0x0A00_0001)),
            IPv4Row(addr: nil),
        ]
        let columns = try ClickHouseRowEncoder().encode(rows)
        let packet = try ClickHouseBlockWriter.encodeDataPacket(
            columns: columns,
            revision: ClickHouseBlockWriter.revisionWithCustomSerialization
        )
        // Nullable(IPv4): 3 mask bytes + 3 * 4 IPv4 bytes = 15 body bytes.
        let body = Array(packet.suffix(3 + 12))
        let block = ClickHouseBlock(
            rowCount: rows.count, columnCount: 1,
            columnNames: [columns[0].name],
            columnTypes: [columns[0].column.typeName],
            bodyStart: 0, bodyLength: body.count
        )
        let decoded = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        let result = try ClickHouseCodableDecoder.decodeRows(type: IPv4Row.self, columns: decoded, rowCount: rows.count)
        #expect(result == rows)
    }
}
