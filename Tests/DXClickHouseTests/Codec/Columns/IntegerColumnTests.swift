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

@Suite("ClickHouse fixed-width integer column")
struct IntegerColumnTests {

    @Test("Int32 column round-trips through encode and decode")
    func int32RoundTrip() throws {
        let column = ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [Int32.min, -1, 0, 1, Int32.max])
        var buffer = ByteBuffer()
        column.encode(into: &buffer)
        #expect(buffer.readableBytes == column.rowCount * 4)

        let decoded = try ClickHouseFixedWidthIntegerColumn<Int32>.decode(spec: .int32, rows: column.rowCount, from: &buffer)
        #expect(decoded.values == column.values)
        #expect(decoded.spec == .int32)
        #expect(buffer.readableBytes == 0)
    }

    @Test("UInt64 column round-trips at boundary values")
    func uint64RoundTrip() throws {
        let values: [UInt64] = [0, 1, UInt64(Int64.max), UInt64.max]
        let column = ClickHouseFixedWidthIntegerColumn<UInt64>(spec: .uint64, values: values)
        var buffer = ByteBuffer()
        column.encode(into: &buffer)

        let decoded = try ClickHouseFixedWidthIntegerColumn<UInt64>.decode(spec: .uint64, rows: column.rowCount, from: &buffer)
        #expect(decoded.values == values)
    }

    @Test("rowCount reflects the values array length")
    func rowCountTracksValues() {
        let column = ClickHouseFixedWidthIntegerColumn<Int8>(spec: .int8, values: [1, 2, 3])
        #expect(column.rowCount == 3)
    }

    @Test("registry decode dispatches to the right integer column for each spec")
    func registryDispatchesPerSpec() throws {
        let cases: [(ClickHouseColumnSpec, [Int64])] = [
            (.int8, [Int64(Int8.min), 0, Int64(Int8.max)]),
            (.int16, [Int64(Int16.min), 0, Int64(Int16.max)]),
            (.int32, [Int64(Int32.min), 0, Int64(Int32.max)]),
            (.int64, [Int64.min, 0, Int64.max]),
            (.uint8, [0, Int64(UInt8.max)]),
            (.uint16, [0, Int64(UInt16.max)]),
            (.uint32, [0, Int64(UInt32.max)]),
        ]

        for (spec, sampleValues) in cases {
            var encodeBuffer = ByteBuffer()
            try writeSampleValues(sampleValues, spec: spec, into: &encodeBuffer)

            let column = try ClickHouseColumnRegistry.decode(spec: spec, rows: sampleValues.count, from: &encodeBuffer)
            #expect(column.spec == spec)
            #expect(column.rowCount == sampleValues.count)
            #expect(encodeBuffer.readableBytes == 0)
        }
    }

    private func writeSampleValues(_ values: [Int64], spec: ClickHouseColumnSpec, into buffer: inout ByteBuffer) throws {
        switch spec {
        case .int8: buffer.writeClickHouseFixedWidthIntegers(values.map { Int8(truncatingIfNeeded: $0) })
        case .int16: buffer.writeClickHouseFixedWidthIntegers(values.map { Int16(truncatingIfNeeded: $0) })
        case .int32: buffer.writeClickHouseFixedWidthIntegers(values.map { Int32(truncatingIfNeeded: $0) })
        case .int64: buffer.writeClickHouseFixedWidthIntegers(values)
        case .uint8: buffer.writeClickHouseFixedWidthIntegers(values.map { UInt8(truncatingIfNeeded: $0) })
        case .uint16: buffer.writeClickHouseFixedWidthIntegers(values.map { UInt16(truncatingIfNeeded: $0) })
        case .uint32: buffer.writeClickHouseFixedWidthIntegers(values.map { UInt32(truncatingIfNeeded: $0) })
        case .uint64: buffer.writeClickHouseFixedWidthIntegers(values.map { UInt64(truncatingIfNeeded: $0) })
        default: Issue.record("unhandled spec \(spec)")
        }
    }

    @Test("decode of an empty column consumes zero bytes")
    func emptyColumnIsNoOp() throws {
        var buffer = ByteBuffer()
        let decoded = try ClickHouseFixedWidthIntegerColumn<Int32>.decode(spec: .int32, rows: 0, from: &buffer)
        #expect(decoded.values.isEmpty)
        #expect(buffer.readableBytes == 0)
    }

    @Test("a truncated buffer surfaces a typed error rather than a partial column")
    func truncatedBufferThrows() {
        let column = ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1, 2, 3])
        var encoded = ByteBuffer()
        column.encode(into: &encoded)

        var truncated = ByteBuffer()
        let bytes = encoded.getBytes(at: encoded.readerIndex, length: 5) ?? []
        truncated.writeBytes(bytes)

        #expect(throws: ClickHouseError.self) {
            try ClickHouseFixedWidthIntegerColumn<Int32>.decode(spec: .int32, rows: 3, from: &truncated)
        }
    }

}
