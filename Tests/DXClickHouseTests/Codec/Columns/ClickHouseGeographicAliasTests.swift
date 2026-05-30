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

@Suite("ClickHouse Geographic type aliases")
struct ClickHouseGeographicAliasTests {

    @Test("Point parses as Tuple(Float64, Float64)")
    func pointParsesAsTuple() throws {
        let parsed = try ClickHouseTypeNameParser.parse("Point")
        #expect(parsed == .tuple(elements: [.float64, .float64]))
    }

    @Test("Ring parses as Array(Tuple(Float64, Float64))")
    func ringParsesAsArrayOfTuple() throws {
        let parsed = try ClickHouseTypeNameParser.parse("Ring")
        #expect(parsed == .array(of: .tuple(elements: [.float64, .float64])))
    }

    @Test("Polygon parses as Array(Array(Tuple(Float64, Float64)))")
    func polygonParsesAsArrayOfArrayOfTuple() throws {
        let parsed = try ClickHouseTypeNameParser.parse("Polygon")
        #expect(parsed == .array(of: .array(of: .tuple(elements: [.float64, .float64]))))
    }

    @Test("MultiPolygon parses as Array(Array(Array(Tuple(Float64, Float64))))")
    func multiPolygonParsesAsArrayOfArrayOfArrayOfTuple() throws {
        let parsed = try ClickHouseTypeNameParser.parse("MultiPolygon")
        let expected: ClickHouseColumnSpec = .array(of: .array(of: .array(of: .tuple(elements: [.float64, .float64]))))
        #expect(parsed == expected)
    }

    @Test("Point and Tuple(Float64, Float64) parse to the same internal spec")
    func pointAndExpandedTupleAreEquivalent() throws {
        let pointSpec = try ClickHouseTypeNameParser.parse("Point")
        let tupleSpec = try ClickHouseTypeNameParser.parse("Tuple(Float64, Float64)")
        #expect(pointSpec == tupleSpec)
    }

    @Test("Ring and the explicit Array(Tuple(Float64, Float64)) parse to the same internal spec")
    func ringAndExpandedArrayAreEquivalent() throws {
        let ringSpec = try ClickHouseTypeNameParser.parse("Ring")
        let arraySpec = try ClickHouseTypeNameParser.parse("Array(Tuple(Float64, Float64))")
        #expect(ringSpec == arraySpec)
    }

    @Test("public typed-INSERT API converts .tupleFloat64Float64 to a TupleColumn of two Float64 columns")
    func publicAPIConvertsTupleFloat64Float64() throws {
        let points: [(Double, Double)] = [(0.0, 0.0), (174.7633, -36.8485), (-122.4194, 37.7749)]
        let column = try ClickHouseClient.toInternalColumn(.tupleFloat64Float64(points))
        let typed = try #require(column as? ClickHouseTupleColumn)
        #expect(typed.spec == .tuple(elements: [.float64, .float64]))
        #expect(typed.rowCount == 3)
        let xColumn = try #require(typed.elements[0] as? ClickHouseFloat64Column)
        let yColumn = try #require(typed.elements[1] as? ClickHouseFloat64Column)
        #expect(xColumn.values == points.map(\.0))
        #expect(yColumn.values == points.map(\.1))
    }

    @Test("a tupleFloat64Float64 column emits a Tuple(Float64, Float64) type name compatible with Point columns")
    func tupleFloat64Float64SpecMatchesPointAlias() throws {
        let column = try ClickHouseClient.toInternalColumn(.tupleFloat64Float64([(1.0, 2.0)]))
        let pointSpec = try ClickHouseTypeNameParser.parse("Point")
        // The type name produced by my Tuple column must parse back to a spec that the Point alias
        // also produces — i.e., the server treats both names interchangeably.
        #expect(column.spec == pointSpec)
        #expect(column.spec.typeName == "Tuple(Float64, Float64)")
    }

    @Test("an empty tupleFloat64Float64 column produces a 0-row tuple with two empty Float64 children")
    func emptyTupleFloat64Float64() throws {
        let column = try ClickHouseClient.toInternalColumn(.tupleFloat64Float64([]))
        let typed = try #require(column as? ClickHouseTupleColumn)
        #expect(typed.rowCount == 0)
    }

    @Test("a tupleFloat64Float64 column round-trips wire bytes via the registry as a Point spec")
    func tupleFloat64Float64RoundTripsAsPoint() throws {
        let original: [(Double, Double)] = [
            (0.0, 0.0),
            (Double.pi, -Double.pi),
            (.greatestFiniteMagnitude, .leastNormalMagnitude)
        ]
        let column = try ClickHouseClient.toInternalColumn(.tupleFloat64Float64(original))
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)

        let pointSpec = try ClickHouseTypeNameParser.parse("Point")
        let decoded = try ClickHouseColumnRegistry.decode(spec: pointSpec, rows: original.count, from: &buffer)
        let typed = try #require(decoded as? ClickHouseTupleColumn)
        let xColumn = try #require(typed.elements[0] as? ClickHouseFloat64Column)
        let yColumn = try #require(typed.elements[1] as? ClickHouseFloat64Column)
        #expect(xColumn.values == original.map(\.0))
        #expect(yColumn.values == original.map(\.1))
        #expect(buffer.readableBytes == 0)
    }

    @Test("public typed-INSERT API converts .arrayOfArrayOfTupleFloat64Float64 to a Polygon column")
    func publicAPIConvertsPolygon() throws {
        // Two polygons:
        //   #1: a square with no hole — single ring of 4 points
        //   #2: a square with one hole — outer ring of 4 points + inner ring of 3 points
        let polygons: [[[(Double, Double)]]] = [
            [
                [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]
            ],
            [
                [(0.0, 0.0), (20.0, 0.0), (20.0, 20.0), (0.0, 20.0)],
                [(5.0, 5.0), (15.0, 5.0), (10.0, 15.0)]
            ]
        ]
        let column = try ClickHouseClient.toInternalColumn(.arrayOfArrayOfTupleFloat64Float64(polygons))
        let typed = try #require(column as? ClickHouseArrayColumn)
        let polygonSpec = try ClickHouseTypeNameParser.parse("Polygon")
        #expect(typed.spec == polygonSpec)
        #expect(typed.rowCount == 2, "two polygons")

        // Inner is the Ring column (Array(Tuple(Float64, Float64)))
        let ringColumn = try #require(typed.inner as? ClickHouseArrayColumn)
        #expect(ringColumn.rowCount == 3, "1 ring (polygon 1) + 2 rings (polygon 2)")

        // Tuple column has all 4 + 4 + 3 = 11 points
        let tupleColumn = try #require(ringColumn.inner as? ClickHouseTupleColumn)
        #expect(tupleColumn.rowCount == 11)
    }

    @Test("public typed-INSERT API converts .arrayOfArrayOfArrayOfTupleFloat64Float64 to a MultiPolygon column")
    func publicAPIConvertsMultiPolygon() throws {
        // One row with a MultiPolygon containing 2 polygons:
        //   Polygon A: a single ring of 3 points
        //   Polygon B: 2 rings (outer 4 + inner 3)
        let multiPolygons: [[[[(Double, Double)]]]] = [
            [
                [
                    [(0.0, 0.0), (1.0, 0.0), (0.5, 1.0)]  // Polygon A: triangle
                ],
                [
                    [(10.0, 10.0), (20.0, 10.0), (20.0, 20.0), (10.0, 20.0)],  // Polygon B outer
                    [(12.0, 12.0), (15.0, 12.0), (13.5, 15.0)]                   // Polygon B inner
                ]
            ]
        ]
        let column = try ClickHouseClient.toInternalColumn(.arrayOfArrayOfArrayOfTupleFloat64Float64(multiPolygons))
        let typed = try #require(column as? ClickHouseArrayColumn)
        let multiPolygonSpec = try ClickHouseTypeNameParser.parse("MultiPolygon")
        #expect(typed.spec == multiPolygonSpec)
        #expect(typed.rowCount == 1, "one multipolygon row")

        // Inner is the Polygon column
        let polygonColumn = try #require(typed.inner as? ClickHouseArrayColumn)
        #expect(polygonColumn.rowCount == 2, "two polygons total")

        // Inside Polygon, Ring column has 1 + 2 = 3 rings
        let ringColumn = try #require(polygonColumn.inner as? ClickHouseArrayColumn)
        #expect(ringColumn.rowCount == 3)

        // Tuple column has 3 + 4 + 3 = 10 points
        let tupleColumn = try #require(ringColumn.inner as? ClickHouseTupleColumn)
        #expect(tupleColumn.rowCount == 10)
    }

    @Test("an empty Polygon column produces a 0-row array")
    func emptyPolygonColumn() throws {
        let column = try ClickHouseClient.toInternalColumn(.arrayOfArrayOfTupleFloat64Float64([]))
        let typed = try #require(column as? ClickHouseArrayColumn)
        #expect(typed.rowCount == 0)
    }

    @Test("an empty MultiPolygon column produces a 0-row array")
    func emptyMultiPolygonColumn() throws {
        let column = try ClickHouseClient.toInternalColumn(.arrayOfArrayOfArrayOfTupleFloat64Float64([]))
        let typed = try #require(column as? ClickHouseArrayColumn)
        #expect(typed.rowCount == 0)
    }

    @Test("Polygon spec produced by the INSERT path matches the Polygon parsed from the type-name string")
    func polygonInsertSpecMatchesParsedAlias() throws {
        let column = try ClickHouseClient.toInternalColumn(.arrayOfArrayOfTupleFloat64Float64([
            [[(1.0, 2.0)]]
        ]))
        let polygonSpec = try ClickHouseTypeNameParser.parse("Polygon")
        #expect(column.spec == polygonSpec, "INSERT-side spec must match parsed Polygon alias for SELECT-side compatibility")
    }

    @Test("MultiPolygon spec produced by the INSERT path matches the MultiPolygon parsed from the type-name string")
    func multiPolygonInsertSpecMatchesParsedAlias() throws {
        let column = try ClickHouseClient.toInternalColumn(.arrayOfArrayOfArrayOfTupleFloat64Float64([
            [[[(1.0, 2.0)]]]
        ]))
        let multiPolygonSpec = try ClickHouseTypeNameParser.parse("MultiPolygon")
        #expect(column.spec == multiPolygonSpec)
    }

    @Test("a Geographic alias spec round-trips wire bytes via the registry")
    func pointWireRoundTripsViaRegistry() throws {
        // Encode 3 points: (0,0), (1.5, -2.5), (Float64.pi, 1e10)
        let xColumn = ClickHouseFloat64Column(values: [0.0, 1.5, Double.pi])
        let yColumn = ClickHouseFloat64Column(values: [0.0, -2.5, 1e10])
        let tupleColumn = ClickHouseTupleColumn(
            spec: .tuple(elements: [.float64, .float64]),
            elementSpecs: [.float64, .float64],
            elements: [xColumn, yColumn],
            rowCount: 3
        )
        var buffer = ByteBuffer()
        try tupleColumn.encode(into: &buffer)

        // Decode using the Point spec — should produce identical content.
        let pointSpec = try ClickHouseTypeNameParser.parse("Point")
        let decoded = try ClickHouseColumnRegistry.decode(spec: pointSpec, rows: 3, from: &buffer)
        let typed = try #require(decoded as? ClickHouseTupleColumn)
        #expect(typed.rowCount == 3)
        #expect(buffer.readableBytes == 0)
    }

}
