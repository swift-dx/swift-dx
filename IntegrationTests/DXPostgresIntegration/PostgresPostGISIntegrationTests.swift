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

import DXPostgres
import Testing

// Round-trips PostGIS geometry over the live extension: a bound PostgresGeometry
// is encoded to EWKB hex, cast to ::geometry, and read back through both the
// binary path (parameterized result) and the text path (simple query / ST_AsText
// confirmation). PostGIS is PostgreSQL-only, so this suite is gated separately
// from the cross-database integration suite.
@Suite(.enabled(if: PostgresIntegration.isPostGISEnabled)) struct PostgresPostGISIntegrationTests {

    private func roundTrip(_ geometry: PostgresGeometry) async throws -> PostgresGeometry {
        try await Postgres.withClient(PostgresIntegration.makePostGISConfiguration()) { postgres in
            try await postgres.query("SELECT $1::geometry AS g", binding: [geometry]).rows[0].decode(PostgresGeometry.self, named: "g")
        }
    }

    @Test func pointRoundTripsThroughPostGIS() async throws {
        let value = PostgresGeometry(srid: 4326, shape: .point(.xy(x: 1.5, y: -2.25)))
        #expect(try await roundTrip(value) == value)
    }

    @Test func zPointRoundTrips() async throws {
        let value = PostgresGeometry(srid: 4326, shape: .point(.xyz(x: 1, y: 2, z: 3)))
        #expect(try await roundTrip(value) == value)
    }

    @Test func lineStringRoundTrips() async throws {
        let value = PostgresGeometry(srid: 0, shape: .lineString([.xy(x: 0, y: 0), .xy(x: 1, y: 1), .xy(x: 2, y: 2)]))
        #expect(try await roundTrip(value) == value)
    }

    @Test func polygonRoundTrips() async throws {
        let ring: [PostgresCoordinate] = [.xy(x: 0, y: 0), .xy(x: 1, y: 0), .xy(x: 1, y: 1), .xy(x: 0, y: 1), .xy(x: 0, y: 0)]
        let value = PostgresGeometry(srid: 4326, shape: .polygon([ring]))
        #expect(try await roundTrip(value) == value)
    }

    @Test func multiPolygonRoundTrips() async throws {
        let first: [[PostgresCoordinate]] = [[.xy(x: 0, y: 0), .xy(x: 1, y: 0), .xy(x: 1, y: 1), .xy(x: 0, y: 0)]]
        let second: [[PostgresCoordinate]] = [[.xy(x: 2, y: 2), .xy(x: 3, y: 2), .xy(x: 3, y: 3), .xy(x: 2, y: 2)]]
        let value = PostgresGeometry(srid: 4326, shape: .multiPolygon([first, second]))
        #expect(try await roundTrip(value) == value)
    }

    @Test func geometryCollectionRoundTrips() async throws {
        let value = PostgresGeometry(srid: 0, shape: .geometryCollection([.point(.xy(x: 1, y: 2)), .lineString([.xy(x: 0, y: 0), .xy(x: 1, y: 1)])]))
        #expect(try await roundTrip(value) == value)
    }

    @Test func decodesServerGeneratedGeometry() async throws {
        try await Postgres.withClient(PostgresIntegration.makePostGISConfiguration()) { postgres in
            let row = try await postgres.query("SELECT ST_GeomFromText('POLYGON((0 0,2 0,2 2,0 2,0 0))', 4326) AS g, $1::int AS marker", binding: [1]).rows[0]
            let geometry = try row.decode(PostgresGeometry.self, named: "g")
            #expect(geometry.srid == 4326)
            guard case .polygon(let rings) = geometry.shape else {
                Issue.record("expected polygon")
                return
            }
            #expect(rings[0].count == 5)
        }
    }

    @Test func encodedGeometryMatchesServerText() async throws {
        try await Postgres.withClient(PostgresIntegration.makePostGISConfiguration()) { postgres in
            let value = PostgresGeometry(srid: 4326, shape: .point(.xy(x: 1, y: 2)))
            let text = try await postgres.query("SELECT ST_AsText($1::geometry) AS t", binding: [value]).rows[0]
            #expect(try text.decode(String.self, named: "t") == "POINT(1 2)")
        }
    }
}
