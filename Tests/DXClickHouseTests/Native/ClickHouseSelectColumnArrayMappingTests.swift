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

@Suite("ClickHouseSelectColumn — Array(T) mapping")
struct ClickHouseSelectColumnArrayMappingTests {

    private static func makeArray<T: ClickHouseColumn>(
        elementSpec: ClickHouseColumnSpec, offsets: [UInt64], inner: T
    ) -> ClickHouseArrayColumn {
        ClickHouseArrayColumn(
            spec: .array(of: elementSpec),
            elementSpec: elementSpec,
            offsets: offsets,
            inner: inner
        )
    }

    // MARK: - Integers

    @Test("Array(Int8) maps to .arrayOfInt8 with row slicing by cumulative offsets")
    func arrayOfInt8Mapping() throws {
        // 3 rows: [10], [20, 30], []
        // Flat inner: [10, 20, 30], cumulative offsets: [1, 3, 3]
        let inner = ClickHouseFixedWidthIntegerColumn<Int8>(spec: .int8, values: [10, 20, 30])
        let column = Self.makeArray(elementSpec: .int8, offsets: [1, 3, 3], inner: inner)
        let publicColumn = try ClickHouseSelectColumn.from(name: "x", internalColumn: column)
        guard case .arrayOfInt8(let values) = publicColumn.values else {
            Issue.record("expected .arrayOfInt8 case")
            return
        }
        #expect(values == [[10], [20, 30], []])
    }

    @Test("Array(Int16/Int32/Int64) slice flat inner values into per-row arrays")
    func arrayOfSignedIntegerMappings() throws {
        let int16 = Self.makeArray(
            elementSpec: .int16, offsets: [2, 4],
            inner: ClickHouseFixedWidthIntegerColumn<Int16>(spec: .int16, values: [-1, 0, 1, 2])
        )
        let int32 = Self.makeArray(
            elementSpec: .int32, offsets: [3],
            inner: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [Int32.min, 0, Int32.max])
        )
        let int64 = Self.makeArray(
            elementSpec: .int64, offsets: [0, 1],
            inner: ClickHouseFixedWidthIntegerColumn<Int64>(spec: .int64, values: [42])
        )

        let int16Pub = try ClickHouseSelectColumn.from(name: "a", internalColumn: int16)
        let int32Pub = try ClickHouseSelectColumn.from(name: "b", internalColumn: int32)
        let int64Pub = try ClickHouseSelectColumn.from(name: "c", internalColumn: int64)

        guard case .arrayOfInt16(let v16) = int16Pub.values,
              case .arrayOfInt32(let v32) = int32Pub.values,
              case .arrayOfInt64(let v64) = int64Pub.values else {
            Issue.record("expected matching array integer cases")
            return
        }
        #expect(v16 == [[-1, 0], [1, 2]])
        #expect(v32 == [[Int32.min, 0, Int32.max]])
        #expect(v64 == [[], [42]])
    }

    @Test("Array(UInt8/16/32/64) slice flat values for unsigned integer types")
    func arrayOfUnsignedIntegerMappings() throws {
        let uint8 = Self.makeArray(
            elementSpec: .uint8, offsets: [1, 3],
            inner: ClickHouseFixedWidthIntegerColumn<UInt8>(spec: .uint8, values: [255, 0, UInt8.max])
        )
        let uint64 = Self.makeArray(
            elementSpec: .uint64, offsets: [2],
            inner: ClickHouseFixedWidthIntegerColumn<UInt64>(spec: .uint64, values: [0, UInt64.max])
        )

        let uint8Pub = try ClickHouseSelectColumn.from(name: "a", internalColumn: uint8)
        let uint64Pub = try ClickHouseSelectColumn.from(name: "b", internalColumn: uint64)

        guard case .arrayOfUInt8(let v8) = uint8Pub.values,
              case .arrayOfUInt64(let v64) = uint64Pub.values else {
            Issue.record("expected matching array unsigned cases")
            return
        }
        #expect(v8 == [[255], [0, UInt8.max]])
        #expect(v64 == [[0, UInt64.max]])
    }

    // MARK: - Floats

    @Test("Array(Float32/64) slice flat inner values into per-row arrays")
    func arrayOfFloatMappings() throws {
        let f32 = Self.makeArray(
            elementSpec: .float32, offsets: [2, 3],
            inner: ClickHouseFloat32Column(values: [.pi, -.pi, 0])
        )
        let f64 = Self.makeArray(
            elementSpec: .float64, offsets: [1, 1, 2],
            inner: ClickHouseFloat64Column(values: [1.5, 2.5])
        )

        let f32Pub = try ClickHouseSelectColumn.from(name: "a", internalColumn: f32)
        let f64Pub = try ClickHouseSelectColumn.from(name: "b", internalColumn: f64)

        guard case .arrayOfFloat32(let v32) = f32Pub.values,
              case .arrayOfFloat64(let v64) = f64Pub.values else {
            Issue.record("expected matching array float cases")
            return
        }
        #expect(v32 == [[.pi, -.pi], [0]])
        #expect(v64 == [[1.5], [], [2.5]])
    }

    // MARK: - String / Bool / UUID

    @Test("Array(String) slices flat string column into per-row arrays")
    func arrayOfStringMapping() throws {
        let column = Self.makeArray(
            elementSpec: .string, offsets: [2, 2, 5],
            inner: ClickHouseStringColumn(values: ["alpha", "beta", "gamma", "delta", "epsilon"])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "tags", internalColumn: column)
        guard case .arrayOfString(let values) = publicColumn.values else {
            Issue.record("expected .arrayOfString case")
            return
        }
        #expect(values == [["alpha", "beta"], [], ["gamma", "delta", "epsilon"]])
    }

    @Test("Array(Bool) slices flat bool column into per-row arrays")
    func arrayOfBoolMapping() throws {
        let column = Self.makeArray(
            elementSpec: .bool, offsets: [3, 4],
            inner: ClickHouseBoolColumn(values: [true, false, true, false])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "flags", internalColumn: column)
        guard case .arrayOfBool(let values) = publicColumn.values else {
            Issue.record("expected .arrayOfBool case")
            return
        }
        #expect(values == [[true, false, true], [false]])
    }

    @Test("Array(UUID) slices flat UUID column into per-row arrays")
    func arrayOfUUIDMapping() throws {
        let id1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let id2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let id3 = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let column = Self.makeArray(
            elementSpec: .uuid, offsets: [1, 3],
            inner: ClickHouseUUIDColumn(values: [id1, id2, id3])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "ids", internalColumn: column)
        guard case .arrayOfUUID(let values) = publicColumn.values else {
            Issue.record("expected .arrayOfUUID case")
            return
        }
        #expect(values == [[id1], [id2, id3]])
    }

    // MARK: - Date / DateTime

    @Test("Array(Date) converts UInt16 days to Date and slices into per-row arrays")
    func arrayOfDateMapping() throws {
        let column = Self.makeArray(
            elementSpec: .date, offsets: [2, 3],
            inner: ClickHouseFixedWidthIntegerColumn<UInt16>(spec: .date, values: [0, 1, 100])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "d", internalColumn: column)
        guard case .arrayOfDate(let dates) = publicColumn.values else {
            Issue.record("expected .arrayOfDate case")
            return
        }
        #expect(dates[0] == [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 86_400)])
        #expect(dates[1] == [Date(timeIntervalSince1970: 86_400 * 100)])
    }

    @Test("Array(DateTime) converts UInt32 seconds to Date and slices into per-row arrays")
    func arrayOfDateTimeMapping() throws {
        let column = Self.makeArray(
            elementSpec: .dateTime(timezone: .serverDefault), offsets: [1, 3],
            inner: ClickHouseFixedWidthIntegerColumn<UInt32>(
                spec: .dateTime(timezone: .serverDefault), values: [0, 1_700_000_000, 1_700_000_001]
            )
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "ts", internalColumn: column)
        guard case .arrayOfDateTime(let dates) = publicColumn.values else {
            Issue.record("expected .arrayOfDateTime case")
            return
        }
        #expect(dates[0] == [Date(timeIntervalSince1970: 0)])
        #expect(dates[1] == [Date(timeIntervalSince1970: 1_700_000_000), Date(timeIntervalSince1970: 1_700_000_001)])
    }

    // MARK: - BFloat16

    @Test("Array(BFloat16) slices flat bfloat16 column for ML feature arrays")
    func arrayOfBFloat16Mapping() throws {
        let halfA = ClickHouseBFloat16(Float(0.5))
        let halfB = ClickHouseBFloat16(Float(-1.0))
        let column = Self.makeArray(
            elementSpec: .bfloat16, offsets: [1, 2],
            inner: ClickHouseBFloat16Column(spec: .bfloat16, values: [halfA, halfB])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "vec", internalColumn: column)
        guard case .arrayOfBFloat16(let values) = publicColumn.values else {
            Issue.record("expected .arrayOfBFloat16 case")
            return
        }
        #expect(values.count == 2)
        #expect(values[0].count == 1)
        #expect(values[1].count == 1)
    }

    // MARK: - Edge cases

    @Test("an empty Array column (no rows) produces an empty outer array")
    func emptyArrayColumn() throws {
        let column = Self.makeArray(
            elementSpec: .int32, offsets: [],
            inner: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "x", internalColumn: column)
        guard case .arrayOfInt32(let values) = publicColumn.values else {
            Issue.record("expected .arrayOfInt32 case")
            return
        }
        #expect(values.isEmpty)
    }

    @Test("an Array column with all empty inner rows preserves the row count")
    func arrayColumnWithEmptyInnerRows() throws {
        // 4 rows, all empty (cumulative offsets stay at 0)
        let column = Self.makeArray(
            elementSpec: .int32, offsets: [0, 0, 0, 0],
            inner: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "x", internalColumn: column)
        guard case .arrayOfInt32(let values) = publicColumn.values else {
            Issue.record("expected .arrayOfInt32 case")
            return
        }
        #expect(values == [[], [], [], []])
    }

    @Test("an Array column with a single huge row places all elements in one inner array")
    func arrayColumnWithSingleHugeRow() throws {
        let bigValues = Array(0..<1000).map { Int32($0) }
        let column = Self.makeArray(
            elementSpec: .int32, offsets: [1000],
            inner: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: bigValues)
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "x", internalColumn: column)
        guard case .arrayOfInt32(let values) = publicColumn.values else {
            Issue.record("expected .arrayOfInt32 case")
            return
        }
        #expect(values.count == 1)
        #expect(values[0] == bigValues)
    }

    // MARK: - Wire round-trip

    @Test("Array(String) wire round-trips through encode/decode and the public mapper")
    func arrayOfStringWireRoundTrip() throws {
        let inner = ClickHouseStringColumn(values: ["alpha", "beta", "gamma", "delta", "epsilon"])
        let original = Self.makeArray(elementSpec: .string, offsets: [2, 2, 5], inner: inner)
        var buffer = ByteBuffer()
        try original.encode(into: &buffer)

        let decoded = try ClickHouseColumnRegistry.decode(spec: .array(of: .string), rows: 3, from: &buffer)
        let publicColumn = try ClickHouseSelectColumn.from(name: "tags", internalColumn: decoded)

        guard case .arrayOfString(let values) = publicColumn.values else {
            Issue.record("expected .arrayOfString case")
            return
        }
        #expect(values == [["alpha", "beta"], [], ["gamma", "delta", "epsilon"]])
        #expect(buffer.readableBytes == 0, "all wire bytes consumed")
    }

    @Test("Array(Int64) wire round-trips with negative and boundary values preserved")
    func arrayOfInt64WireRoundTrip() throws {
        let inner = ClickHouseFixedWidthIntegerColumn<Int64>(spec: .int64, values: [Int64.min, -1, 0, 1, Int64.max])
        let original = Self.makeArray(elementSpec: .int64, offsets: [2, 5], inner: inner)
        var buffer = ByteBuffer()
        try original.encode(into: &buffer)

        let decoded = try ClickHouseColumnRegistry.decode(spec: .array(of: .int64), rows: 2, from: &buffer)
        let publicColumn = try ClickHouseSelectColumn.from(name: "ints", internalColumn: decoded)

        guard case .arrayOfInt64(let values) = publicColumn.values else {
            Issue.record("expected .arrayOfInt64 case")
            return
        }
        #expect(values == [[Int64.min, -1], [0, 1, Int64.max]])
        #expect(buffer.readableBytes == 0, "all wire bytes consumed")
    }

    // MARK: - Unsupported element types

    @Test("Array(Nullable(T)) throws unsupportedSelectColumnType — no Values case for that combination")
    func arrayOfNullableThrowsUnsupported() throws {
        // Build an Array(Nullable(Int32)) — the public Values enum has no `arrayOfNullableInt32`.
        let nullableInner = ClickHouseNullableColumn(
            spec: .nullable(of: .int32), innerSpec: .int32,
            nullMask: [false, true],
            inner: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [42, 0])
        )
        let arrayColumn = Self.makeArray(
            elementSpec: .nullable(of: .int32), offsets: [2], inner: nullableInner
        )
        #expect(throws: ClickHouseError.self) {
            try ClickHouseSelectColumn.from(name: "n", internalColumn: arrayColumn)
        }
    }

}
