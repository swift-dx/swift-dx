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

@Suite("DXClickHouse Geo alias type-name expansion")
struct ClickHouseGeoTypeNameExpansionTests {

    @Test("Point expands to Tuple(Float64, Float64)")
    func pointExpands() {
        #expect(ClickHouseGeoTypeName.expand("Point") == "Tuple(Float64, Float64)")
    }

    @Test("Ring expands to Array(Tuple(Float64, Float64))")
    func ringExpands() {
        #expect(ClickHouseGeoTypeName.expand("Ring") == "Array(Tuple(Float64, Float64))")
    }

    @Test("LineString expands to Array(Tuple(Float64, Float64))")
    func lineStringExpands() {
        #expect(ClickHouseGeoTypeName.expand("LineString") == "Array(Tuple(Float64, Float64))")
    }

    @Test("Polygon expands to Array(Array(Tuple(Float64, Float64)))")
    func polygonExpands() {
        #expect(ClickHouseGeoTypeName.expand("Polygon") == "Array(Array(Tuple(Float64, Float64)))")
    }

    @Test("MultiLineString expands to Array(Array(Tuple(Float64, Float64)))")
    func multiLineStringExpands() {
        #expect(ClickHouseGeoTypeName.expand("MultiLineString") == "Array(Array(Tuple(Float64, Float64)))")
    }

    @Test("Geo aliases nested inside Array of Ring expand in place")
    func nestedRingInArrayExpands() {
        #expect(ClickHouseGeoTypeName.expand("Array(Ring)") == "Array(Array(Tuple(Float64, Float64)))")
        #expect(ClickHouseGeoTypeName.expand("Array(LineString)") == "Array(Array(Tuple(Float64, Float64)))")
    }

    @Test("MultiPolygon expands to Array(Array(Array(Tuple(Float64, Float64))))")
    func multiPolygonExpands() {
        #expect(ClickHouseGeoTypeName.expand("MultiPolygon") == "Array(Array(Array(Tuple(Float64, Float64))))")
    }

    @Test("Geo aliases nested inside Array expand in place")
    func nestedPointInArrayExpands() {
        #expect(ClickHouseGeoTypeName.expand("Array(Point)") == "Array(Tuple(Float64, Float64))")
    }

    @Test("Nested expands to Array(Tuple) preserving element names")
    func nestedExpands() {
        #expect(ClickHouseGeoTypeName.expand("Nested(a UInt64, b String)") == "Array(Tuple(a UInt64, b String))")
    }

    @Test("Non-Geo type names pass through unchanged")
    func nonGeoUnchanged() {
        #expect(ClickHouseGeoTypeName.expand("Map(String, UInt64)") == "Map(String, UInt64)")
        #expect(ClickHouseGeoTypeName.expand("UInt64") == "UInt64")
        #expect(ClickHouseGeoTypeName.expand("Tuple(UInt64, String)") == "Tuple(UInt64, String)")
    }
}
