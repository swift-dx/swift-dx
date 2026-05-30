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

@Suite("ClickHouseSelectColumn — Tuple and Geographic mapping")
struct ClickHouseSelectColumnTupleMappingTests {

    private static func makeTuple(
        elementSpecs: [ClickHouseColumnSpec],
        elements: [any ClickHouseColumn],
        rowCount: Int
    ) -> ClickHouseTupleColumn {
        ClickHouseTupleColumn(
            spec: .tuple(elements: elementSpecs),
            elementSpecs: elementSpecs,
            elements: elements,
            rowCount: rowCount
        )
    }

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

    // MARK: - Pair tuples

    @Test("Tuple(Float64, Float64) maps to .tupleFloat64Float64 — coordinates")
    func tupleFloat64Float64Mapping() throws {
        let xColumn = ClickHouseFloat64Column(values: [174.7633, -36.8485, 0.0])
        let yColumn = ClickHouseFloat64Column(values: [-36.8485, 174.7633, 0.0])
        let tuple = Self.makeTuple(
            elementSpecs: [.float64, .float64],
            elements: [xColumn, yColumn],
            rowCount: 3
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "loc", internalColumn: tuple)
        guard case .tupleFloat64Float64(let pairs) = publicColumn.values else {
            Issue.record("expected .tupleFloat64Float64 case")
            return
        }
        #expect(pairs.count == 3)
        #expect(pairs[0] == (174.7633, -36.8485))
        #expect(pairs[1] == (-36.8485, 174.7633))
        #expect(pairs[2] == (0.0, 0.0))
    }

    @Test("Tuple(String, String) maps to .tupleStringString")
    func tupleStringStringMapping() throws {
        let firstColumn = ClickHouseStringColumn(values: ["en", "fr", "de"])
        let secondColumn = ClickHouseStringColumn(values: ["English", "French", "German"])
        let tuple = Self.makeTuple(
            elementSpecs: [.string, .string],
            elements: [firstColumn, secondColumn],
            rowCount: 3
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "lang", internalColumn: tuple)
        guard case .tupleStringString(let pairs) = publicColumn.values else {
            Issue.record("expected .tupleStringString case")
            return
        }
        #expect(pairs.count == 3)
        #expect(pairs[0] == ("en", "English"))
        #expect(pairs[2] == ("de", "German"))
    }

    @Test("Tuple(String, Int32) maps to .tupleStringInt32")
    func tupleStringInt32Mapping() throws {
        let firstColumn = ClickHouseStringColumn(values: ["a", "b"])
        let secondColumn = ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1, 2])
        let tuple = Self.makeTuple(
            elementSpecs: [.string, .int32],
            elements: [firstColumn, secondColumn],
            rowCount: 2
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "x", internalColumn: tuple)
        guard case .tupleStringInt32(let pairs) = publicColumn.values else {
            Issue.record("expected .tupleStringInt32 case")
            return
        }
        #expect(pairs.count == 2)
        #expect(pairs[0] == ("a", 1))
        #expect(pairs[1] == ("b", 2))
    }

    @Test("Tuple(String, Int64) maps to .tupleStringInt64")
    func tupleStringInt64Mapping() throws {
        let firstColumn = ClickHouseStringColumn(values: ["x"])
        let secondColumn = ClickHouseFixedWidthIntegerColumn<Int64>(spec: .int64, values: [Int64.max])
        let tuple = Self.makeTuple(
            elementSpecs: [.string, .int64],
            elements: [firstColumn, secondColumn],
            rowCount: 1
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "x", internalColumn: tuple)
        guard case .tupleStringInt64(let pairs) = publicColumn.values else {
            Issue.record("expected .tupleStringInt64 case")
            return
        }
        #expect(pairs.count == 1)
        #expect(pairs[0] == ("x", Int64.max))
    }

    @Test("Tuple of unsupported shape (Int32, Int32) throws unsupportedSelectColumnType")
    func tupleOfUnsupportedShapeThrows() throws {
        let firstColumn = ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1])
        let secondColumn = ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [2])
        let tuple = Self.makeTuple(
            elementSpecs: [.int32, .int32],
            elements: [firstColumn, secondColumn],
            rowCount: 1
        )
        #expect(throws: ClickHouseError.self) {
            try ClickHouseSelectColumn.from(name: "x", internalColumn: tuple)
        }
    }

    @Test("3-element Tuple throws unsupportedSelectColumnType (only pairs supported)")
    func tripleTupleThrows() throws {
        let columns: [any ClickHouseColumn] = [
            ClickHouseStringColumn(values: ["a"]),
            ClickHouseStringColumn(values: ["b"]),
            ClickHouseStringColumn(values: ["c"])
        ]
        let tuple = Self.makeTuple(
            elementSpecs: [.string, .string, .string],
            elements: columns,
            rowCount: 1
        )
        #expect(throws: ClickHouseError.self) {
            try ClickHouseSelectColumn.from(name: "x", internalColumn: tuple)
        }
    }

    // MARK: - Geographic types: Ring, Polygon, MultiPolygon

    @Test("Ring (Array(Tuple(Float64, Float64))) maps to .arrayOfTupleFloat64Float64")
    func ringMapping() throws {
        // 2 rings: [(0,0), (1,0), (1,1)] and [(2,2)]
        // Flat tuples: [(0,0), (1,0), (1,1), (2,2)]
        // Ring offsets (cumulative): [3, 4]
        let xColumn = ClickHouseFloat64Column(values: [0, 1, 1, 2])
        let yColumn = ClickHouseFloat64Column(values: [0, 0, 1, 2])
        let tuple = Self.makeTuple(
            elementSpecs: [.float64, .float64],
            elements: [xColumn, yColumn],
            rowCount: 4
        )
        let ring = Self.makeArray(
            elementSpec: .tuple(elements: [.float64, .float64]),
            offsets: [3, 4],
            inner: tuple
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "ring", internalColumn: ring)
        guard case .arrayOfTupleFloat64Float64(let rings) = publicColumn.values else {
            Issue.record("expected .arrayOfTupleFloat64Float64 case")
            return
        }
        #expect(rings.count == 2)
        #expect(rings[0].count == 3)
        #expect(rings[0][0] == (0, 0))
        #expect(rings[0][2] == (1, 1))
        #expect(rings[1].count == 1)
        #expect(rings[1][0] == (2, 2))
    }

    @Test("Polygon (Array(Array(Tuple(Float64, Float64)))) maps with 2 levels of slicing")
    func polygonMapping() throws {
        // 2 polygons:
        //   polygon[0] = single ring: [(0,0), (10,0), (10,10), (0,10)]
        //   polygon[1] = two rings: outer [(0,0), (20,0), (20,20), (0,20)], inner [(5,5), (15,5), (10,15)]
        // Flat tuples (4+4+3=11):
        //   (0,0), (10,0), (10,10), (0,10),
        //   (0,0), (20,0), (20,20), (0,20),
        //   (5,5), (15,5), (10,15)
        // Ring offsets (cumulative): [4, 8, 11]
        // Polygon offsets (cumulative ring count): [1, 3]
        let xs = [0.0, 10, 10, 0, 0, 20, 20, 0, 5, 15, 10]
        let ys = [0.0, 0, 10, 10, 0, 0, 20, 20, 5, 5, 15]
        let tuple = Self.makeTuple(
            elementSpecs: [.float64, .float64],
            elements: [ClickHouseFloat64Column(values: xs), ClickHouseFloat64Column(values: ys)],
            rowCount: 11
        )
        let ringArray = Self.makeArray(
            elementSpec: .tuple(elements: [.float64, .float64]),
            offsets: [4, 8, 11],
            inner: tuple
        )
        let polygon = Self.makeArray(
            elementSpec: .array(of: .tuple(elements: [.float64, .float64])),
            offsets: [1, 3],
            inner: ringArray
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "poly", internalColumn: polygon)
        guard case .arrayOfArrayOfTupleFloat64Float64(let polygons) = publicColumn.values else {
            Issue.record("expected .arrayOfArrayOfTupleFloat64Float64 case")
            return
        }
        #expect(polygons.count == 2, "two polygons")
        #expect(polygons[0].count == 1, "polygon[0] has 1 ring")
        #expect(polygons[0][0].count == 4)
        #expect(polygons[0][0][0] == (0, 0))
        #expect(polygons[0][0][2] == (10, 10))
        #expect(polygons[1].count == 2, "polygon[1] has 2 rings")
        #expect(polygons[1][0].count == 4, "outer ring of polygon[1]")
        #expect(polygons[1][1].count == 3, "inner ring of polygon[1]")
        #expect(polygons[1][1][2] == (10, 15))
    }

    @Test("MultiPolygon maps with 3 levels of slicing")
    func multiPolygonMapping() throws {
        // 1 multipolygon containing 2 polygons:
        //   polygon A = single ring of 3 points (a triangle)
        //   polygon B = 2 rings: outer 4 + inner 3
        // Flat tuples (3+4+3=10):
        //   triangle: (0,0), (1,0), (0.5,1)
        //   B outer: (10,10), (20,10), (20,20), (10,20)
        //   B inner: (12,12), (15,12), (13.5,15)
        let xs = [0.0, 1, 0.5, 10, 20, 20, 10, 12, 15, 13.5]
        let ys = [0.0, 0, 1.0, 10, 10, 20, 20, 12, 12, 15]
        let tuple = Self.makeTuple(
            elementSpecs: [.float64, .float64],
            elements: [ClickHouseFloat64Column(values: xs), ClickHouseFloat64Column(values: ys)],
            rowCount: 10
        )
        // Ring offsets (cumulative): triangle ends at 3; B outer at 7; B inner at 10
        let ringArray = Self.makeArray(
            elementSpec: .tuple(elements: [.float64, .float64]),
            offsets: [3, 7, 10],
            inner: tuple
        )
        // Polygon offsets (cumulative ring count): polygon A has 1 ring, polygon B has 2 rings
        // So cumulative: [1, 3]
        let polygonArray = Self.makeArray(
            elementSpec: .array(of: .tuple(elements: [.float64, .float64])),
            offsets: [1, 3],
            inner: ringArray
        )
        // MultiPolygon offsets (cumulative polygon count for each row): 1 row = 2 polygons -> [2]
        let multiPolygon = Self.makeArray(
            elementSpec: .array(of: .array(of: .tuple(elements: [.float64, .float64]))),
            offsets: [2],
            inner: polygonArray
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "geom", internalColumn: multiPolygon)
        guard case .arrayOfArrayOfArrayOfTupleFloat64Float64(let multiPolygons) = publicColumn.values else {
            Issue.record("expected .arrayOfArrayOfArrayOfTupleFloat64Float64 case")
            return
        }
        #expect(multiPolygons.count == 1, "one row")
        #expect(multiPolygons[0].count == 2, "two polygons in the row")
        #expect(multiPolygons[0][0].count == 1, "polygon A has 1 ring")
        #expect(multiPolygons[0][0][0].count == 3, "triangle has 3 points")
        #expect(multiPolygons[0][1].count == 2, "polygon B has 2 rings")
        #expect(multiPolygons[0][1][0].count == 4, "B outer has 4 points")
        #expect(multiPolygons[0][1][1].count == 3, "B inner has 3 points")
        #expect(multiPolygons[0][1][1][2] == (13.5, 15))
    }

    @Test("an empty Ring column produces an empty array")
    func emptyRingColumn() throws {
        let tuple = Self.makeTuple(
            elementSpecs: [.float64, .float64],
            elements: [ClickHouseFloat64Column(values: []), ClickHouseFloat64Column(values: [])],
            rowCount: 0
        )
        let ring = Self.makeArray(
            elementSpec: .tuple(elements: [.float64, .float64]),
            offsets: [],
            inner: tuple
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "ring", internalColumn: ring)
        guard case .arrayOfTupleFloat64Float64(let values) = publicColumn.values else {
            Issue.record("expected .arrayOfTupleFloat64Float64 case")
            return
        }
        #expect(values.isEmpty)
    }

    // MARK: - Wire round-trip

    @Test("Tuple(Float64, Float64) wire round-trips through encode/decode and the public mapper")
    func tupleFloat64Float64WireRoundTrip() throws {
        let xColumn = ClickHouseFloat64Column(values: [0.0, .pi, 1e10])
        let yColumn = ClickHouseFloat64Column(values: [0.0, -.pi, -1e10])
        let original = Self.makeTuple(
            elementSpecs: [.float64, .float64],
            elements: [xColumn, yColumn],
            rowCount: 3
        )
        var buffer = ByteBuffer()
        try original.encode(into: &buffer)

        let decoded = try ClickHouseColumnRegistry.decode(
            spec: .tuple(elements: [.float64, .float64]), rows: 3, from: &buffer
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "p", internalColumn: decoded)

        guard case .tupleFloat64Float64(let pairs) = publicColumn.values else {
            Issue.record("expected .tupleFloat64Float64 case")
            return
        }
        #expect(pairs.count == 3)
        #expect(pairs[0] == (0.0, 0.0))
        #expect(pairs[1] == (.pi, -.pi))
        #expect(buffer.readableBytes == 0)
    }

    @Test("Polygon spec wire round-trips and the public mapper preserves nested structure")
    func polygonWireRoundTrip() throws {
        // Single polygon, single ring of 3 points (triangle).
        let xs = [0.0, 1, 0.5]
        let ys = [0.0, 0, 1.0]
        let tuple = Self.makeTuple(
            elementSpecs: [.float64, .float64],
            elements: [ClickHouseFloat64Column(values: xs), ClickHouseFloat64Column(values: ys)],
            rowCount: 3
        )
        let ringArray = Self.makeArray(
            elementSpec: .tuple(elements: [.float64, .float64]),
            offsets: [3],
            inner: tuple
        )
        let polygon = Self.makeArray(
            elementSpec: .array(of: .tuple(elements: [.float64, .float64])),
            offsets: [1],
            inner: ringArray
        )
        var buffer = ByteBuffer()
        try polygon.encode(into: &buffer)

        let polygonSpec = try ClickHouseTypeNameParser.parse("Polygon")
        let decoded = try ClickHouseColumnRegistry.decode(spec: polygonSpec, rows: 1, from: &buffer)
        let publicColumn = try ClickHouseSelectColumn.from(name: "geom", internalColumn: decoded)

        guard case .arrayOfArrayOfTupleFloat64Float64(let polygons) = publicColumn.values else {
            Issue.record("expected .arrayOfArrayOfTupleFloat64Float64 case")
            return
        }
        #expect(polygons.count == 1)
        #expect(polygons[0].count == 1, "one ring")
        #expect(polygons[0][0].count == 3, "triangle")
        #expect(polygons[0][0][0] == (0, 0))
        #expect(polygons[0][0][2] == (0.5, 1))
        #expect(buffer.readableBytes == 0)
    }

}
