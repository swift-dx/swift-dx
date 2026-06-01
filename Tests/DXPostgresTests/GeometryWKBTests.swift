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

import Testing

@testable import DXPostgres

// EWKB hex fixtures were captured from PostGIS 3.5 via `geometry::text`, so these
// decode tests pin DXPostgres against the format the server actually emits.
@Suite struct GeometryWKBTests {

    @Test func decodesSridPoint() throws {
        let geometry = try PostgresWKBDecoding.decodeHex("0101000020E6100000000000000000F03F0000000000000040")
        #expect(geometry == PostgresGeometry(srid: 4326, shape: .point(.xy(x: 1, y: 2))))
    }

    @Test func decodesPointWithoutSrid() throws {
        let geometry = try PostgresWKBDecoding.decodeHex("0101000000000000000000F03F0000000000000040")
        #expect(geometry == PostgresGeometry(srid: 0, shape: .point(.xy(x: 1, y: 2))))
    }

    @Test func decodesZPoint() throws {
        let geometry = try PostgresWKBDecoding.decodeHex("01010000A0E6100000000000000000F03F00000000000000400000000000000840")
        #expect(geometry == PostgresGeometry(srid: 4326, shape: .point(.xyz(x: 1, y: 2, z: 3))))
    }

    @Test func decodesMultiPolygon() throws {
        let hex = "0106000020E6100000020000000103000000010000000400000000000000000000000000000000000000000000000000F03F0000000000000000000000000000F03F000000000000F03F000000000000000000000000000000000103000000010000000400000000000000000000400000000000000040000000000000084000000000000000400000000000000840000000000000084000000000000000400000000000000040"
        let geometry = try PostgresWKBDecoding.decodeHex(hex)
        #expect(geometry.srid == 4326)
        guard case .multiPolygon(let polygons) = geometry.shape else {
            Issue.record("expected multiPolygon")
            return
        }
        #expect(polygons.count == 2)
        #expect(polygons[0][0].count == 4)
        #expect(polygons[0][0][0] == .xy(x: 0, y: 0))
        #expect(polygons[1][0][1] == .xy(x: 3, y: 2))
    }

    @Test func decodesGeometryCollection() throws {
        let hex = "0107000000020000000101000000000000000000F03F000000000000004001020000000200000000000000000000000000000000000000000000000000F03F000000000000F03F"
        let geometry = try PostgresWKBDecoding.decodeHex(hex)
        guard case .geometryCollection(let shapes) = geometry.shape else {
            Issue.record("expected geometryCollection")
            return
        }
        #expect(shapes.count == 2)
        #expect(shapes[0] == .point(.xy(x: 1, y: 2)))
        #expect(shapes[1] == .lineString([.xy(x: 0, y: 0), .xy(x: 1, y: 1)]))
    }

    @Test func roundTripsThroughEncoder() throws {
        let geometries: [PostgresGeometry] = [
            PostgresGeometry(srid: 4326, shape: .point(.xy(x: 1.25, y: -2.5))),
            PostgresGeometry(srid: 0, shape: .lineString([.xy(x: 0, y: 0), .xy(x: 3, y: 4), .xy(x: 5, y: 6)])),
            PostgresGeometry(srid: 4326, shape: .polygon([[.xy(x: 0, y: 0), .xy(x: 1, y: 0), .xy(x: 1, y: 1), .xy(x: 0, y: 0)]])),
            PostgresGeometry(srid: 0, shape: .multiPoint([.xy(x: 1, y: 1), .xy(x: 2, y: 2)])),
            PostgresGeometry(srid: 4326, shape: .point(.xyzm(x: 1, y: 2, z: 3, m: 4))),
            PostgresGeometry(srid: 0, shape: .geometryCollection([.point(.xy(x: 9, y: 9)), .lineString([.xy(x: 0, y: 0), .xy(x: 1, y: 1)])])),
        ]
        for geometry in geometries {
            let reDecoded = try PostgresWKBDecoding.decode(PostgresWKBEncoding.encode(geometry))
            #expect(reDecoded == geometry)
        }
    }

    @Test func rejectsTruncatedBytes() {
        #expect(throws: PostgresError.self) {
            try PostgresWKBDecoding.decode([0x01, 0x01, 0x00])
        }
    }

    @Test func rejectsInvalidHex() {
        #expect(throws: PostgresError.self) {
            try PostgresWKBDecoding.decodeHex("zzzz")
        }
    }

    @Test func rejectsExcessivelyNestedGeometry() {
        var bytes: [UInt8] = []
        for _ in 0..<100 {
            bytes.append(0x01)
            bytes.append(contentsOf: [0x07, 0, 0, 0])
            bytes.append(contentsOf: [0x01, 0, 0, 0])
        }
        bytes.append(0x01)
        bytes.append(contentsOf: [0x01, 0, 0, 0])
        bytes.append(contentsOf: Array(repeating: 0, count: 16))
        #expect(throws: PostgresError.self) {
            try PostgresWKBDecoding.decode(bytes)
        }
    }

    @Test func rejectsMixedDimensionWithinSequence() {
        let mixed = PostgresGeometry(srid: 0, shape: .lineString([.xy(x: 0, y: 0), .xyz(x: 1, y: 1, z: 1)]))
        #expect(throws: PostgresError.self) {
            _ = try PostgresWKBEncoding.encode(mixed)
        }
    }

    @Test func allowsDifferingDimensionsAcrossCollectionChildren() throws {
        let geometry = PostgresGeometry(srid: 0, shape: .geometryCollection([.point(.xy(x: 1, y: 2)), .point(.xyz(x: 3, y: 4, z: 5))]))
        let reDecoded = try PostgresWKBDecoding.decode(PostgresWKBEncoding.encode(geometry))
        #expect(reDecoded == geometry)
    }
}
