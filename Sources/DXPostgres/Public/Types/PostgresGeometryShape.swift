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

/// The shape of a PostGIS geometry, mirroring the seven OGC well-known-binary
/// geometry kinds. A polygon is an array of rings (the first is the exterior
/// boundary, the rest are holes); a multi-polygon is an array of such ring sets.
/// A geometry collection nests heterogeneous shapes, so this enum is `indirect`.
public indirect enum PostgresGeometryShape: Sendable, Equatable {

    case point(PostgresCoordinate)
    case lineString([PostgresCoordinate])
    case polygon([[PostgresCoordinate]])
    case multiPoint([PostgresCoordinate])
    case multiLineString([[PostgresCoordinate]])
    case multiPolygon([[[PostgresCoordinate]]])
    case geometryCollection([PostgresGeometryShape])

    var wkbType: UInt32 {
        switch self {
        case .point: 1
        case .lineString: 2
        case .polygon: 3
        case .multiPoint: 4
        case .multiLineString: 5
        case .multiPolygon: 6
        case .geometryCollection: 7
        }
    }

    var flattenedCoordinates: [PostgresCoordinate] {
        switch self {
        case .point(let coordinate): [coordinate]
        case .lineString(let coordinates): coordinates
        case .polygon(let rings): rings.flatMap { $0 }
        case .multiPoint(let coordinates): coordinates
        case .multiLineString(let lines): lines.flatMap { $0 }
        case .multiPolygon(let polygons): polygons.flatMap { $0.flatMap { $0 } }
        case .geometryCollection(let shapes): shapes.flatMap { $0.flattenedCoordinates }
        }
    }

    var dimension: WKBDimension {
        for coordinate in flattenedCoordinates {
            return coordinate.dimension
        }
        return .xy
    }
}
