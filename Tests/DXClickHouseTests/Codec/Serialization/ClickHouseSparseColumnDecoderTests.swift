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

@Suite("ClickHouse sparse column decoder")
struct ClickHouseSparseColumnDecoderTests {

    private static let endOfGranuleFlag: UInt64 = 1 << 62

    @Test("all-default Bool — only the terminator UVarInt encodes the trailing-default count")
    func allDefaultBool() throws {
        var buffer = ByteBuffer()
        // 1 row, all defaults. No offsets, terminator = (1 | END_OF_GRANULE_FLAG).
        buffer.writeClickHouseUVarInt(1 | Self.endOfGranuleFlag)
        // No nested values follow.

        let column = try ClickHouseSparseColumnDecoder.decode(spec: .bool, rows: 1, from: &buffer)
        let typed = try #require(column as? ClickHouseBoolColumn)

        #expect(typed.values == [false])
        #expect(buffer.readableBytes == 0)
    }

    @Test("single non-default Bool at position 2 of 5 rows")
    func singleNonDefaultBool() throws {
        var buffer = ByteBuffer()
        // 5 rows. offsets[0] = 2 → group_size = 2 (two defaults, then one
        // non-default at position 2). After: cursor = 3. Trailing defaults
        // = 5 - 3 = 2. Terminator = (2 | END_OF_GRANULE_FLAG).
        buffer.writeClickHouseUVarInt(2)
        buffer.writeClickHouseUVarInt(2 | Self.endOfGranuleFlag)
        buffer.writeClickHouseBool(true)

        let column = try ClickHouseSparseColumnDecoder.decode(spec: .bool, rows: 5, from: &buffer)
        let typed = try #require(column as? ClickHouseBoolColumn)

        #expect(typed.values == [false, false, true, false, false])
        #expect(buffer.readableBytes == 0)
    }

    @Test("multiple non-default Int32 values at scattered positions")
    func multipleNonDefaultInts() throws {
        var buffer = ByteBuffer()
        // 10 rows. Non-defaults at positions 1, 5, 8.
        // group_size_0 = 1 - 0 = 1; cursor = 2
        // group_size_1 = 5 - 2 = 3; cursor = 6
        // group_size_2 = 8 - 6 = 2; cursor = 9
        // trailing = 10 - 9 = 1
        buffer.writeClickHouseUVarInt(1)
        buffer.writeClickHouseUVarInt(3)
        buffer.writeClickHouseUVarInt(2)
        buffer.writeClickHouseUVarInt(1 | Self.endOfGranuleFlag)
        // Three Int32 values, little-endian.
        buffer.writeClickHouseFixedWidthIntegers([Int32(100), Int32(200), Int32(300)])

        let column = try ClickHouseSparseColumnDecoder.decode(spec: .int32, rows: 10, from: &buffer)
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<Int32>)

        #expect(typed.values == [0, 100, 0, 0, 0, 200, 0, 0, 300, 0])
        #expect(buffer.readableBytes == 0)
    }

    @Test("non-default String values at the head and tail of the column")
    func nonDefaultStrings() throws {
        var buffer = ByteBuffer()
        // 4 rows. Non-default at positions 0 and 3.
        // group_size_0 = 0 - 0 = 0; cursor = 1
        // group_size_1 = 3 - 1 = 2; cursor = 4
        // trailing = 4 - 4 = 0
        buffer.writeClickHouseUVarInt(0)
        buffer.writeClickHouseUVarInt(2)
        buffer.writeClickHouseUVarInt(0 | Self.endOfGranuleFlag)
        buffer.writeClickHouseStrings(["alpha", "omega"])

        let column = try ClickHouseSparseColumnDecoder.decode(spec: .string, rows: 4, from: &buffer)
        let typed = try #require(column as? ClickHouseStringColumn)

        #expect(typed.values == ["alpha", "", "", "omega"])
        #expect(buffer.readableBytes == 0)
    }

    @Test("sparse-encoded IPv4 column decodes through the UInt32 scatter path (registry/scatter type-pairing must match)")
    func sparseIPv4UsesUInt32Scatter() throws {
        // ClickHouseColumnRegistry decodes `.ipv4` as
        // `ClickHouseFixedWidthIntegerColumn<UInt32>` — IPv4 addresses
        // are unsigned 32-bit integers. The sparse scatter must
        // dispatch `.ipv4` to the same UInt32 scatter group; if it
        // wrongly groups `.ipv4` with the Int32 specs (date32,
        // decimal32, time, int32), the `as? ClickHouseFixedWidthInteger
        // Column<Int32>` downcast fails and `sparseScatterTypeMismatch`
        // is thrown for any sparse-encoded ipv4 column.
        var buffer = ByteBuffer()
        // 4 rows, one non-default at position 1.
        // group_size_0 = 1; cursor = 2; trailing = 4 - 2 = 2.
        buffer.writeClickHouseUVarInt(1)
        buffer.writeClickHouseUVarInt(2 | Self.endOfGranuleFlag)
        // Single non-default IPv4 value: 192.0.2.1 → 0xC0000201.
        buffer.writeClickHouseFixedWidthIntegers([UInt32(0xC000_0201)])

        let column = try ClickHouseSparseColumnDecoder.decode(spec: .ipv4, rows: 4, from: &buffer)
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<UInt32>)
        #expect(typed.values == [0, 0xC000_0201, 0, 0])
        #expect(buffer.readableBytes == 0)
    }

    @Test("offsets exceeding totalRows throw a typed error rather than wrapping")
    func offsetsExceedingTotalThrow() {
        var buffer = ByteBuffer()
        // Claim two non-defaults in a row-count of 1: cursor walks past the end.
        buffer.writeClickHouseUVarInt(0)
        buffer.writeClickHouseUVarInt(0)
        buffer.writeClickHouseUVarInt(0 | Self.endOfGranuleFlag)
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseSparseColumnDecoder.decode(spec: .int32, rows: 1, from: &buffer)
        }
    }

    @Test("trailing-defaults mismatch with cursor surfaces a typed error")
    func trailingDefaultsMismatchThrows() {
        var buffer = ByteBuffer()
        // 5 rows, one non-default at 0, but terminator claims 10 trailing.
        buffer.writeClickHouseUVarInt(0)
        buffer.writeClickHouseUVarInt(10 | Self.endOfGranuleFlag)
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseSparseColumnDecoder.decode(spec: .int32, rows: 5, from: &buffer)
        }
    }

    @Test("composite specs reject sparse serialization at the boundary")
    func compositeSpecRejected() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseUVarInt(0 | Self.endOfGranuleFlag)
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseSparseColumnDecoder.decode(spec: .nullable(of: .int32), rows: 0, from: &buffer)
        }
    }

    @Test("Block.decode dispatches sparse-encoded columns to the sparse decoder")
    func blockDecodeDispatchesSparse() throws {
        var buffer = ByteBuffer()
        // BlockInfo: legacy is_overflows + bucket_num framing.
        ClickHouseBlockInfo().encode(into: &buffer)
        // 1 column, 3 rows.
        buffer.writeClickHouseUVarInt(1)
        buffer.writeClickHouseUVarInt(3)
        // Column header: name, type name, hasCustomSerialization=true, kind=sparse
        buffer.writeClickHouseString("flag")
        buffer.writeClickHouseString("Bool")
        buffer.writeClickHouseBool(true)
        buffer.writeInteger(UInt8(1))
        // Sparse body: non-default at position 1.
        buffer.writeClickHouseUVarInt(1)
        buffer.writeClickHouseUVarInt(1 | Self.endOfGranuleFlag)
        buffer.writeClickHouseBool(true)

        let block = try ClickHouseBlock.decode(from: &buffer, revision: 54_454)
        let column = try #require(block.columns.first?.column as? ClickHouseBoolColumn)

        #expect(block.rowCount == 3)
        #expect(column.values == [false, true, false])
        #expect(buffer.readableBytes == 0)
    }

}
