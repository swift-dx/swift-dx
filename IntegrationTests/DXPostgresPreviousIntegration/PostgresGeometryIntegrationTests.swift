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

import DXPostgresPrevious
import Testing

// Round-trips the built-in geometric types over both the binary path (a bound
// parameter casts the text rendering and the result returns in binary) and the
// text path (a simple query returns the value in text). Exercised against both
// PostgreSQL and YugabyteDB, which share these types.
@Suite(.enabled(if: PostgresIntegration.isEnabled)) struct PostgresGeometryIntegrationTests {

    @Test func pointRoundTripsBinaryAndText() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let value = PostgresPoint(x: 1.5, y: -2.25)
            let binary = try await postgres.query("SELECT $1::point AS g", binding: [value]).rows[0]
            #expect(try binary.decode(PostgresPoint.self, named: "g") == value)
            let text = try await postgres.query("SELECT '(3,4)'::point AS g").rows[0]
            #expect(try text.decode(PostgresPoint.self, named: "g") == PostgresPoint(x: 3, y: 4))
        }
    }

    @Test func lineRoundTripsBinaryAndText() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let value = PostgresLine(a: 1, b: -2, c: 3)
            let binary = try await postgres.query("SELECT $1::line AS g", binding: [value]).rows[0]
            #expect(try binary.decode(PostgresLine.self, named: "g") == value)
            let text = try await postgres.query("SELECT '{2,3,4}'::line AS g").rows[0]
            #expect(try text.decode(PostgresLine.self, named: "g") == PostgresLine(a: 2, b: 3, c: 4))
        }
    }

    @Test func lineSegmentRoundTripsBinaryAndText() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let value = PostgresLineSegment(start: PostgresPoint(x: 0, y: 0), end: PostgresPoint(x: 3, y: 4))
            let binary = try await postgres.query("SELECT $1::lseg AS g", binding: [value]).rows[0]
            #expect(try binary.decode(PostgresLineSegment.self, named: "g") == value)
            let text = try await postgres.query("SELECT '[(1,1),(2,2)]'::lseg AS g").rows[0]
            #expect(try text.decode(PostgresLineSegment.self, named: "g").end == PostgresPoint(x: 2, y: 2))
        }
    }

    @Test func boxRoundTripsBinaryAndText() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let value = PostgresBox(upperRight: PostgresPoint(x: 2, y: 2), lowerLeft: PostgresPoint(x: 0, y: 0))
            let binary = try await postgres.query("SELECT $1::box AS g", binding: [value]).rows[0]
            #expect(try binary.decode(PostgresBox.self, named: "g") == value)
            let text = try await postgres.query("SELECT '(3,3),(1,1)'::box AS g").rows[0]
            #expect(try text.decode(PostgresBox.self, named: "g").upperRight == PostgresPoint(x: 3, y: 3))
        }
    }

    @Test func circleRoundTripsBinaryAndText() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let value = PostgresCircle(center: PostgresPoint(x: 1, y: 2), radius: 3)
            let binary = try await postgres.query("SELECT $1::circle AS g", binding: [value]).rows[0]
            #expect(try binary.decode(PostgresCircle.self, named: "g") == value)
            let text = try await postgres.query("SELECT '<(4,5),6>'::circle AS g").rows[0]
            #expect(try text.decode(PostgresCircle.self, named: "g").radius == 6)
        }
    }

    @Test func pathRoundTripsBinaryAndText() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let value = PostgresPath(isClosed: true, points: [PostgresPoint(x: 0, y: 0), PostgresPoint(x: 1, y: 1), PostgresPoint(x: 2, y: 0)])
            let binary = try await postgres.query("SELECT $1::path AS g", binding: [value]).rows[0]
            #expect(try binary.decode(PostgresPath.self, named: "g") == value)
            let text = try await postgres.query("SELECT '[(0,0),(1,1)]'::path AS g").rows[0]
            let decoded = try text.decode(PostgresPath.self, named: "g")
            #expect(decoded.isClosed == false)
            #expect(decoded.points.count == 2)
        }
    }

    @Test func polygonRoundTripsBinaryAndText() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let value = PostgresPolygon(points: [PostgresPoint(x: 0, y: 0), PostgresPoint(x: 1, y: 0), PostgresPoint(x: 1, y: 1)])
            let binary = try await postgres.query("SELECT $1::polygon AS g", binding: [value]).rows[0]
            #expect(try binary.decode(PostgresPolygon.self, named: "g") == value)
            let text = try await postgres.query("SELECT '((0,0),(2,0),(2,2),(0,2))'::polygon AS g").rows[0]
            #expect(try text.decode(PostgresPolygon.self, named: "g").points.count == 4)
        }
    }
}
