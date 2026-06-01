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

import DXCore
import NIOCore

// Encodes a PostgresGeometry to little-endian PostGIS Extended Well-Known Binary.
// The top-level geometry carries the SRID flag and value when its SRID is
// non-zero; nested geometries inside multi-shapes and collections are written as
// standalone EWKB without an SRID, matching PostGIS output. Coordinate
// dimensionality is taken from the shape and reflected in each type word.
enum PostgresWKBEncoding {

    static func encode(_ geometry: PostgresGeometry) throws(PostgresError) -> [UInt8] {
        var buffer = ByteBuffer()
        try writeGeometry(&buffer, geometry.shape, srid: geometry.srid, includeSRID: geometry.srid != 0)
        return Array(buffer.readableBytesView)
    }

    static func encodeHex(_ geometry: PostgresGeometry) throws(PostgresError) -> String {
        Hex.encodeLower(try encode(geometry))
    }

    // The type word's Z/M flags are stamped from the shape's dimension, while the
    // body writes each coordinate's own components. Threading that dimension down
    // to writeCoordinate and rejecting any coordinate that disagrees keeps the
    // header and the byte stream consistent, so a mixed-dimension shape is a typed
    // error rather than silently corrupt EWKB. Children of a collection or
    // multi-geometry recompute their own dimension, so they may legitimately
    // differ from one another.
    private static func writeGeometry(_ buffer: inout ByteBuffer, _ shape: PostgresGeometryShape, srid: Int32, includeSRID: Bool) throws(PostgresError) {
        let dimension = shape.dimension
        let typeWord = shape.wkbType
            | flag(dimension.hasZ, 0x8000_0000)
            | flag(dimension.hasM, 0x4000_0000)
            | flag(includeSRID, 0x2000_0000)
        buffer.writeInteger(UInt8(1))
        buffer.writeInteger(typeWord, endianness: .little)
        writeSRID(&buffer, srid, includeSRID)
        try writeBody(&buffer, shape, dimension: dimension)
    }

    private static func writeBody(_ buffer: inout ByteBuffer, _ shape: PostgresGeometryShape, dimension: WKBDimension) throws(PostgresError) {
        switch shape {
        case .point(let coordinate): try writeCoordinate(&buffer, coordinate, dimension: dimension)
        case .lineString(let coordinates): try writeCoordinates(&buffer, coordinates, dimension: dimension)
        case .polygon(let rings): try writeRings(&buffer, rings, dimension: dimension)
        case .multiPoint(let coordinates): try writeChildren(&buffer, coordinates.map { .point($0) })
        case .multiLineString(let lines): try writeChildren(&buffer, lines.map { .lineString($0) })
        case .multiPolygon(let polygons): try writeChildren(&buffer, polygons.map { .polygon($0) })
        case .geometryCollection(let shapes): try writeChildren(&buffer, shapes)
        }
    }

    private static func writeRings(_ buffer: inout ByteBuffer, _ rings: [[PostgresCoordinate]], dimension: WKBDimension) throws(PostgresError) {
        buffer.writeInteger(UInt32(rings.count), endianness: .little)
        for ring in rings {
            try writeCoordinates(&buffer, ring, dimension: dimension)
        }
    }

    private static func writeCoordinates(_ buffer: inout ByteBuffer, _ coordinates: [PostgresCoordinate], dimension: WKBDimension) throws(PostgresError) {
        buffer.writeInteger(UInt32(coordinates.count), endianness: .little)
        for coordinate in coordinates {
            try writeCoordinate(&buffer, coordinate, dimension: dimension)
        }
    }

    private static func writeChildren(_ buffer: inout ByteBuffer, _ shapes: [PostgresGeometryShape]) throws(PostgresError) {
        buffer.writeInteger(UInt32(shapes.count), endianness: .little)
        for shape in shapes {
            try writeGeometry(&buffer, shape, srid: 0, includeSRID: false)
        }
    }

    private static func writeCoordinate(_ buffer: inout ByteBuffer, _ coordinate: PostgresCoordinate, dimension: WKBDimension) throws(PostgresError) {
        guard coordinate.dimension == dimension else {
            throw PostgresError.protocolError(reason: "geometry mixes coordinate dimensions within a single component sequence")
        }
        for value in coordinate.components {
            buffer.writeInteger(value.bitPattern, endianness: .little)
        }
    }

    private static func writeSRID(_ buffer: inout ByteBuffer, _ srid: Int32, _ includeSRID: Bool) {
        guard includeSRID else { return }
        buffer.writeInteger(UInt32(bitPattern: srid), endianness: .little)
    }

    private static func flag(_ present: Bool, _ bit: UInt32) -> UInt32 {
        present ? bit : 0
    }
}
