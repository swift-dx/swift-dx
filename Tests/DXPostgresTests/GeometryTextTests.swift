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

@Suite struct GeometryTextTests {

    @Test func parsesPoint() throws {
        let point = try PostgresGeometryText.point("(1.5,-2.25)")
        #expect(point == PostgresPoint(x: 1.5, y: -2.25))
        #expect(point.description == "(1.5,-2.25)")
    }

    @Test func parsesLine() throws {
        #expect(try PostgresGeometryText.line("{1,2,3}") == PostgresLine(a: 1, b: 2, c: 3))
    }

    @Test func parsesLineSegment() throws {
        let segment = try PostgresGeometryText.lineSegment("[(0,0),(3,4)]")
        #expect(segment == PostgresLineSegment(start: PostgresPoint(x: 0, y: 0), end: PostgresPoint(x: 3, y: 4)))
    }

    @Test func parsesBox() throws {
        let box = try PostgresGeometryText.box("(2,2),(0,0)")
        #expect(box == PostgresBox(upperRight: PostgresPoint(x: 2, y: 2), lowerLeft: PostgresPoint(x: 0, y: 0)))
    }

    @Test func parsesCircle() throws {
        let circle = try PostgresGeometryText.circle("<(1,2),3>")
        #expect(circle == PostgresCircle(center: PostgresPoint(x: 1, y: 2), radius: 3))
    }

    @Test func parsesClosedAndOpenPaths() throws {
        let closed = try PostgresGeometryText.path("((0,0),(1,1),(2,0))")
        #expect(closed.isClosed == true)
        #expect(closed.points.count == 3)
        let open = try PostgresGeometryText.path("[(0,0),(1,1)]")
        #expect(open.isClosed == false)
        #expect(open.points == [PostgresPoint(x: 0, y: 0), PostgresPoint(x: 1, y: 1)])
    }

    @Test func parsesPolygon() throws {
        let polygon = try PostgresGeometryText.polygon("((0,0),(1,0),(1,1),(0,1))")
        #expect(polygon.points.count == 4)
        #expect(polygon.description == "((0.0,0.0),(1.0,0.0),(1.0,1.0),(0.0,1.0))")
    }

    @Test func parsesScientificNotation() throws {
        #expect(try PostgresGeometryText.point("(1.5e2,-3e-1)") == PostgresPoint(x: 150, y: -0.3))
    }

    @Test func rejectsWrongArity() {
        #expect(throws: PostgresError.self) {
            try PostgresGeometryText.point("(1,2,3)")
        }
        #expect(throws: PostgresError.self) {
            try PostgresGeometryText.lineSegment("(1,2,3)")
        }
    }

    @Test func rejectsOddPolygonCoordinates() {
        #expect(throws: PostgresError.self) {
            try PostgresGeometryText.polygon("((0,0),(1,1),(2))")
        }
    }
}
