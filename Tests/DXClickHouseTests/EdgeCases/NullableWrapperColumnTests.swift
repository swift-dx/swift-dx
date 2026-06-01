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

// Nullable(T) for the non-scalar wrapper column kinds (DateTime64,
// FixedString, Enum8/16, Date32, IPv4/IPv6, Int128/UInt128, Int256/UInt256,
// Decimal). These route through the recursive
// ClickHouseTypedColumn.nullable(mask:inner:) case rather than a flat
// nullable scalar case. The wire body is one null-mask byte per row
// (0 present, 1 null) followed by the inner column body at full row count,
// with null rows holding zero-byte sentinels.
@Suite("DXClickHouse Nullable(wrapper) columns")
struct ClickHouseNullableWrapperColumnTests {

    struct NullableIPv4Row: Codable, Sendable, Equatable { let v: ClickHouseIPv4? }
    struct NullableDecimalRow: Codable, Sendable, Equatable { let v: ClickHouseDecimal? }
    struct NullableDateTime64Row: Codable, Sendable, Equatable { let v: ClickHouseDateTime64? }

    @Test("Encoder lowers ClickHouseIPv4? to Nullable(IPv4) with mask and sentinel")
    func encodesNullableIPv4() throws {
        let rows = [
            NullableIPv4Row(v: ClickHouseIPv4(raw: 0x7F00_0001)),
            NullableIPv4Row(v: nil),
        ]
        let columns = try ClickHouseRowEncoder().encode(rows)
        #expect(columns[0].column.typeName == "Nullable(IPv4)")
        guard case .nullable(let mask, let inner) = columns[0].column else {
            Issue.record("expected nullable column, got \(columns[0].column.typeName)")
            return
        }
        #expect(mask == [false, true])
        guard case .ipv4(let values) = inner else {
            Issue.record("expected ipv4 inner, got \(inner.typeName)")
            return
        }
        #expect(values == [0x7F00_0001, 0])
    }

    @Test("Nullable(IPv4) writes two mask bytes then two little-endian addresses")
    func nullableIPv4WireBytes() throws {
        let rows = [
            NullableIPv4Row(v: ClickHouseIPv4(raw: 0x7F00_0001)),
            NullableIPv4Row(v: nil),
        ]
        let columns = try ClickHouseRowEncoder().encode(rows)
        let packet = try ClickHouseBlockWriter.encodeDataPacket(
            columns: columns,
            revision: ClickHouseBlockWriter.revisionWithCustomSerialization
        )
        var expected: [UInt8] = [0, 1]
        withUnsafeBytes(of: UInt32(0x7F00_0001).littleEndian) { expected.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(0).littleEndian) { expected.append(contentsOf: $0) }
        #expect(Array(packet.suffix(expected.count)) == expected)
    }

    @Test("Decoder parses a Nullable(IPv4) block into a recursive nullable column")
    func decodesNullableIPv4Block() throws {
        var body: [UInt8] = [0, 1]
        withUnsafeBytes(of: UInt32(0x7F00_0001).littleEndian) { body.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(0).littleEndian) { body.append(contentsOf: $0) }
        let block = ClickHouseBlock(
            rowCount: 2,
            columnCount: 1,
            columnNames: ["v"],
            columnTypes: ["Nullable(IPv4)"],
            bodyStart: 0,
            bodyLength: body.count
        )
        let columns = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        guard case .nullable(let mask, let inner) = columns[0].column else {
            Issue.record("expected nullable column, got \(columns[0].column.typeName)")
            return
        }
        #expect(mask == [false, true])
        guard case .ipv4(let values) = inner else {
            Issue.record("expected ipv4 inner, got \(inner.typeName)")
            return
        }
        #expect(values == [0x7F00_0001, 0])
    }

    @Test("Nullable(IPv4) round-trips a present and a NULL row through Codable")
    func nullableIPv4RoundTrip() throws {
        let column: [ClickHouseNamedColumn] = [
            ClickHouseNamedColumn(
                name: "v",
                column: .nullable(mask: [false, true], inner: .ipv4([0x7F00_0001, 0]))
            )
        ]
        let rows = try ClickHouseCodableDecoder.decodeRows(type: NullableIPv4Row.self, columns: column, rowCount: 2)
        #expect(rows == [
            NullableIPv4Row(v: ClickHouseIPv4(raw: 0x7F00_0001)),
            NullableIPv4Row(v: nil),
        ])
    }

    @Test("Nullable(Decimal(18, 4)) writes mask then 8-byte limbs and decodes back")
    func nullableDecimalRoundTrip() throws {
        let value = ClickHouseDecimal(unscaled: 1_234_567, precision: 18, scale: 4)
        let rows = [
            NullableDecimalRow(v: value),
            NullableDecimalRow(v: nil),
        ]
        let columns = try ClickHouseRowEncoder().encode(rows)
        #expect(columns[0].column.typeName == "Nullable(Decimal(18, 4))")
        let packet = try ClickHouseBlockWriter.encodeDataPacket(
            columns: columns,
            revision: ClickHouseBlockWriter.revisionWithCustomSerialization
        )
        var expected: [UInt8] = [0, 1]
        withUnsafeBytes(of: UInt64(1_234_567).littleEndian) { expected.append(contentsOf: $0) }
        expected.append(contentsOf: [UInt8](repeating: 0, count: 8))
        #expect(Array(packet.suffix(expected.count)) == expected)

        let decoded = try ClickHouseCodableDecoder.decodeRows(
            type: NullableDecimalRow.self,
            columns: columns,
            rowCount: 2
        )
        #expect(decoded == [NullableDecimalRow(v: value), NullableDecimalRow(v: nil)])
    }

    @Test("Nullable(DateTime64) keeps precision through the recursive nullable wrap")
    func nullableDateTime64RoundTrip() throws {
        let value = ClickHouseDateTime64(ticks: 1_700_000_000_123_456_789, precision: 9)
        let rows = [
            NullableDateTime64Row(v: value),
            NullableDateTime64Row(v: nil),
        ]
        let columns = try ClickHouseRowEncoder().encode(rows)
        #expect(columns[0].column.typeName == "Nullable(DateTime64(9))")
        let decoded = try ClickHouseCodableDecoder.decodeRows(
            type: NullableDateTime64Row.self,
            columns: columns,
            rowCount: 2
        )
        #expect(decoded == [NullableDateTime64Row(v: value), NullableDateTime64Row(v: nil)])
    }
}
