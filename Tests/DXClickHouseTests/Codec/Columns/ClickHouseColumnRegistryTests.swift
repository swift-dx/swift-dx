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
import NIOCore
import Testing

@Suite("ClickHouse column registry")
struct ClickHouseColumnRegistryTests {

    private static let everySpec: [ClickHouseColumnSpec] = [
        .int8, .int16, .int32, .int64, .int128,
        .uint8, .uint16, .uint32, .uint64, .uint128,
        .float32, .float64,
        .string, .fixedString(length: 4), .bool, .uuid,
        .date, .date32, .dateTime(timezone: .serverDefault), .dateTime(timezone: .explicit("UTC")),
        .dateTime64(precision: 3, timezone: .serverDefault), .dateTime64(precision: 9, timezone: .explicit("Pacific/Auckland")),
        .ipv4, .ipv6,
        .array(of: .int32),
        .nullable(of: .string),
        .tuple(elements: [.int32, .string, .bool]),
        .map(key: .string, value: .int64),
        .lowCardinality(of: .string),
        .enum8([.init(name: "OK", value: 0), .init(name: "FAIL", value: 1)]),
        .enum16([.init(name: "low", value: -1), .init(name: "high", value: 1000)]),
        .decimal32(scale: 2),
        .decimal64(scale: 8),
        .decimal128(scale: 18),
        .array(of: .nullable(of: .string)),
    ]

    @Test("registry returns a column whose spec matches the requested spec")
    func decodedColumnReportsRequestedSpec() throws {
        for spec in Self.everySpec {
            var buffer = ByteBuffer()
            try writeOneSampleRow(for: spec, into: &buffer)
            try ClickHouseColumnRegistry.decodePrefix(spec: spec, from: &buffer)
            let column = try ClickHouseColumnRegistry.decode(spec: spec, rows: 1, from: &buffer)
            #expect(column.spec == spec)
            #expect(column.rowCount == 1)
        }
    }

    @Test("registry decode of zero rows consumes zero bytes for every spec")
    func zeroRowDecodeIsNoOp() throws {
        for spec in Self.everySpec {
            var buffer = ByteBuffer()
            let column = try ClickHouseColumnRegistry.decode(spec: spec, rows: 0, from: &buffer)
            #expect(column.rowCount == 0)
            #expect(buffer.readableBytes == 0)
        }
    }

    @Test("encode then registry decode round-trips for every primitive integer spec")
    func roundTripPerIntegerSpec() throws {
        let cases: [(ClickHouseColumnSpec, () -> any ClickHouseColumn)] = [
            (.int8, { ClickHouseFixedWidthIntegerColumn<Int8>(spec: .int8, values: [-1, 0, 1]) }),
            (.int16, { ClickHouseFixedWidthIntegerColumn<Int16>(spec: .int16, values: [-1, 0, 1]) }),
            (.int32, { ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [-1, 0, 1]) }),
            (.int64, { ClickHouseFixedWidthIntegerColumn<Int64>(spec: .int64, values: [-1, 0, 1]) }),
            (.uint8, { ClickHouseFixedWidthIntegerColumn<UInt8>(spec: .uint8, values: [0, 1, 255]) }),
            (.uint16, { ClickHouseFixedWidthIntegerColumn<UInt16>(spec: .uint16, values: [0, 1, 65535]) }),
            (.uint32, { ClickHouseFixedWidthIntegerColumn<UInt32>(spec: .uint32, values: [0, 1, UInt32.max]) }),
            (.uint64, { ClickHouseFixedWidthIntegerColumn<UInt64>(spec: .uint64, values: [0, 1, UInt64.max]) }),
        ]

        for (spec, factory) in cases {
            let original = factory()
            var buffer = ByteBuffer()
            try original.encode(into: &buffer)
            let decoded = try ClickHouseColumnRegistry.decode(spec: spec, rows: original.rowCount, from: &buffer)
            #expect(decoded.spec == spec)
            #expect(decoded.rowCount == original.rowCount)
            #expect(buffer.readableBytes == 0)
        }
    }

    private func writeOneSampleRow(for spec: ClickHouseColumnSpec, into buffer: inout ByteBuffer) throws {
        try writeSampleRows(rows: 1, spec: spec, into: &buffer)
    }

    private func writeSampleRows(rows: Int, spec: ClickHouseColumnSpec, into buffer: inout ByteBuffer) throws {
        switch spec {
        case .int8: buffer.writeClickHouseFixedWidthIntegers(Array(repeating: Int8(0), count: rows))
        case .int16: buffer.writeClickHouseFixedWidthIntegers(Array(repeating: Int16(0), count: rows))
        case .int32: buffer.writeClickHouseFixedWidthIntegers(Array(repeating: Int32(0), count: rows))
        case .int64: buffer.writeClickHouseFixedWidthIntegers(Array(repeating: Int64(0), count: rows))
        case .int128: buffer.writeClickHouseFixedWidthIntegers(Array(repeating: Int128(0), count: rows))
        case .uint8: buffer.writeClickHouseFixedWidthIntegers(Array(repeating: UInt8(0), count: rows))
        case .uint16: buffer.writeClickHouseFixedWidthIntegers(Array(repeating: UInt16(0), count: rows))
        case .uint32: buffer.writeClickHouseFixedWidthIntegers(Array(repeating: UInt32(0), count: rows))
        case .uint64: buffer.writeClickHouseFixedWidthIntegers(Array(repeating: UInt64(0), count: rows))
        case .uint128: buffer.writeClickHouseFixedWidthIntegers(Array(repeating: UInt128(0), count: rows))
        case .float32: buffer.writeClickHouseFloat32s(Array(repeating: Float32(0), count: rows))
        case .float64: buffer.writeClickHouseFloat64s(Array(repeating: Float64(0), count: rows))
        case .string:
            for _ in 0..<rows { buffer.writeClickHouseString("") }
        case .fixedString(let length):
            buffer.writeBytes(Array(repeating: UInt8(0), count: length * rows))
        case .bool: buffer.writeClickHouseBools(Array(repeating: false, count: rows))
        case .uuid:
            for _ in 0..<rows { buffer.writeClickHouseUUID(UUID()) }
        case .date: buffer.writeClickHouseFixedWidthIntegers(Array(repeating: UInt16(0), count: rows))
        case .date32: buffer.writeClickHouseFixedWidthIntegers(Array(repeating: Int32(0), count: rows))
        case .dateTime: buffer.writeClickHouseFixedWidthIntegers(Array(repeating: UInt32(0), count: rows))
        case .dateTime64: buffer.writeClickHouseFixedWidthIntegers(Array(repeating: Int64(0), count: rows))
        case .ipv4: buffer.writeClickHouseFixedWidthIntegers(Array(repeating: UInt32(0), count: rows))
        case .ipv6: buffer.writeBytes(Array(repeating: UInt8(0), count: 16 * rows))
        case .array(let elementSpec):
            // One element per row, so cumulative offsets are [1, 2, ..., rows]
            buffer.writeClickHouseFixedWidthIntegers((1...max(rows, 1)).prefix(rows).map(UInt64.init))
            try writeSampleRows(rows: rows, spec: elementSpec, into: &buffer)
        case .nullable(let innerSpec):
            buffer.writeBytes(Array(repeating: UInt8(0), count: rows))
            try writeSampleRows(rows: rows, spec: innerSpec, into: &buffer)
        case .tuple(let elementSpecs):
            for elementSpec in elementSpecs {
                try writeSampleRows(rows: rows, spec: elementSpec, into: &buffer)
            }
        case .map(let keySpec, let valueSpec):
            buffer.writeClickHouseFixedWidthIntegers((1...max(rows, 1)).prefix(rows).map(UInt64.init))
            try writeSampleRows(rows: rows, spec: keySpec, into: &buffer)
            try writeSampleRows(rows: rows, spec: valueSpec, into: &buffer)
        case .lowCardinality(let innerSpec):
            guard rows > 0 else { return }
            buffer.writeInteger(UInt64(1), endianness: .little)
            buffer.writeInteger(UInt64(0) | (UInt64(1) << 9), endianness: .little)
            buffer.writeInteger(UInt64(rows), endianness: .little)
            try writeSampleRows(rows: rows, spec: innerSpec, into: &buffer)
            buffer.writeInteger(UInt64(rows), endianness: .little)
            for index in 0..<rows {
                buffer.writeInteger(UInt8(index), endianness: .little)
            }
        case .enum8: buffer.writeClickHouseFixedWidthIntegers(Array(repeating: Int8(0), count: rows))
        case .enum16: buffer.writeClickHouseFixedWidthIntegers(Array(repeating: Int16(0), count: rows))
        case .decimal32: buffer.writeClickHouseFixedWidthIntegers(Array(repeating: Int32(0), count: rows))
        case .decimal64: buffer.writeClickHouseFixedWidthIntegers(Array(repeating: Int64(0), count: rows))
        case .decimal128: buffer.writeClickHouseFixedWidthIntegers(Array(repeating: Int128(0), count: rows))
        case .time: buffer.writeClickHouseFixedWidthIntegers(Array(repeating: Int32(0), count: rows))
        case .time64: buffer.writeClickHouseFixedWidthIntegers(Array(repeating: Int64(0), count: rows))
        case .interval: buffer.writeClickHouseFixedWidthIntegers(Array(repeating: Int64(0), count: rows))
        case .int256: buffer.writeBytes(Array(repeating: UInt8(0), count: 32 * rows))
        case .uint256: buffer.writeBytes(Array(repeating: UInt8(0), count: 32 * rows))
        case .decimal256: buffer.writeBytes(Array(repeating: UInt8(0), count: 32 * rows))
        case .bfloat16: buffer.writeClickHouseFixedWidthIntegers(Array(repeating: UInt16(0), count: rows))
        case .nothing:
            // Zero bytes per row — Nothing has no payload.
            break
        case .json:
            for _ in 0..<rows { buffer.writeClickHouseString("") }
        }
    }

}
