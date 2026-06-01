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

// Decodes PostGIS Extended Well-Known Binary into a PostgresGeometry. Each
// geometry begins with a byte-order flag and a type word whose high bits mark
// the Z, M, and SRID presence (the SRID itself, when flagged, follows on the
// top-level geometry only). Multi-geometries and collections embed full child
// EWKB geometries, each with its own header, so reading recurses.
enum PostgresWKBDecoding {

    static func decodeHex(_ text: String) throws(PostgresError) -> PostgresGeometry {
        let bytes: [UInt8]
        do {
            bytes = try Hex.decode(text)
        } catch {
            throw PostgresError.typeDecodingFailed(type: "PostgresGeometry", reason: "geometry text is not valid EWKB hex")
        }
        return try decode(bytes)
    }

    // EWKB nesting is shallow in practice (a collection of multi-geometries is
    // two levels); this bound rejects crafted blobs whose deep collection nesting
    // would otherwise recurse the decoder into a stack overflow.
    private static let maxNestingDepth = 64

    static func decode(_ bytes: [UInt8]) throws(PostgresError) -> PostgresGeometry {
        var buffer = ByteBuffer(bytes: bytes)
        let geometry = try readGeometry(&buffer, depth: 0)
        return geometry
    }

    private static func readGeometry(_ buffer: inout ByteBuffer, depth: Int) throws(PostgresError) -> PostgresGeometry {
        guard depth <= maxNestingDepth else {
            throw PostgresError.typeDecodingFailed(type: "PostgresGeometry", reason: "WKB nesting exceeds \(maxNestingDepth) levels")
        }
        let endianness = try readByteOrder(&buffer)
        let descriptor = WKBTypeDescriptor(try readUInt32(&buffer, endianness))
        let srid = try descriptor.hasSRID ? Int32(bitPattern: readUInt32(&buffer, endianness)) : 0
        let shape = try readShape(&buffer, endianness, descriptor, depth: depth)
        return PostgresGeometry(srid: srid, shape: shape)
    }

    private static func readShape(_ buffer: inout ByteBuffer, _ endianness: Endianness, _ descriptor: WKBTypeDescriptor, depth: Int) throws(PostgresError) -> PostgresGeometryShape {
        switch descriptor.wkbType {
        case 1: return .point(try readCoordinate(&buffer, endianness, descriptor))
        case 2: return .lineString(try readCoordinates(&buffer, endianness, descriptor))
        case 3: return .polygon(try readRings(&buffer, endianness, descriptor))
        case 4: return .multiPoint(try readPoints(&buffer, endianness, depth: depth))
        case 5: return .multiLineString(try readLines(&buffer, endianness, depth: depth))
        case 6: return .multiPolygon(try readPolygons(&buffer, endianness, depth: depth))
        case 7: return .geometryCollection(try readShapes(&buffer, endianness, depth: depth))
        default: throw PostgresError.typeDecodingFailed(type: "PostgresGeometry", reason: "unsupported WKB geometry type \(descriptor.wkbType)")
        }
    }

    // A length prefix is attacker-controlled, so never reserve more slots than the
    // remaining bytes could possibly fill (each element needs at least one byte).
    private static func boundedCapacity(_ count: UInt32, _ buffer: ByteBuffer) -> Int {
        min(Int(count), buffer.readableBytes)
    }

    private static func readRings(_ buffer: inout ByteBuffer, _ endianness: Endianness, _ descriptor: WKBTypeDescriptor) throws(PostgresError) -> [[PostgresCoordinate]] {
        let count = try readUInt32(&buffer, endianness)
        var rings: [[PostgresCoordinate]] = []
        rings.reserveCapacity(boundedCapacity(count, buffer))
        for _ in 0..<count {
            rings.append(try readCoordinates(&buffer, endianness, descriptor))
        }
        return rings
    }

    private static func readCoordinates(_ buffer: inout ByteBuffer, _ endianness: Endianness, _ descriptor: WKBTypeDescriptor) throws(PostgresError) -> [PostgresCoordinate] {
        let count = try readUInt32(&buffer, endianness)
        var coordinates: [PostgresCoordinate] = []
        coordinates.reserveCapacity(boundedCapacity(count, buffer))
        for _ in 0..<count {
            coordinates.append(try readCoordinate(&buffer, endianness, descriptor))
        }
        return coordinates
    }

    private static func readPoints(_ buffer: inout ByteBuffer, _ endianness: Endianness, depth: Int) throws(PostgresError) -> [PostgresCoordinate] {
        let children = try readChildren(&buffer, endianness, depth: depth)
        var coordinates: [PostgresCoordinate] = []
        coordinates.reserveCapacity(children.count)
        for child in children {
            guard case .point(let coordinate) = child else {
                throw PostgresError.typeDecodingFailed(type: "PostgresGeometry", reason: "MultiPoint element is not a Point")
            }
            coordinates.append(coordinate)
        }
        return coordinates
    }

    private static func readLines(_ buffer: inout ByteBuffer, _ endianness: Endianness, depth: Int) throws(PostgresError) -> [[PostgresCoordinate]] {
        let children = try readChildren(&buffer, endianness, depth: depth)
        var lines: [[PostgresCoordinate]] = []
        lines.reserveCapacity(children.count)
        for child in children {
            guard case .lineString(let coordinates) = child else {
                throw PostgresError.typeDecodingFailed(type: "PostgresGeometry", reason: "MultiLineString element is not a LineString")
            }
            lines.append(coordinates)
        }
        return lines
    }

    private static func readPolygons(_ buffer: inout ByteBuffer, _ endianness: Endianness, depth: Int) throws(PostgresError) -> [[[PostgresCoordinate]]] {
        let children = try readChildren(&buffer, endianness, depth: depth)
        var polygons: [[[PostgresCoordinate]]] = []
        polygons.reserveCapacity(children.count)
        for child in children {
            guard case .polygon(let rings) = child else {
                throw PostgresError.typeDecodingFailed(type: "PostgresGeometry", reason: "MultiPolygon element is not a Polygon")
            }
            polygons.append(rings)
        }
        return polygons
    }

    private static func readShapes(_ buffer: inout ByteBuffer, _ endianness: Endianness, depth: Int) throws(PostgresError) -> [PostgresGeometryShape] {
        let count = try readUInt32(&buffer, endianness)
        var shapes: [PostgresGeometryShape] = []
        shapes.reserveCapacity(boundedCapacity(count, buffer))
        for _ in 0..<count {
            shapes.append(try readGeometry(&buffer, depth: depth + 1).shape)
        }
        return shapes
    }

    private static func readChildren(_ buffer: inout ByteBuffer, _ endianness: Endianness, depth: Int) throws(PostgresError) -> [PostgresGeometryShape] {
        let count = try readUInt32(&buffer, endianness)
        var children: [PostgresGeometryShape] = []
        children.reserveCapacity(boundedCapacity(count, buffer))
        for _ in 0..<count {
            children.append(try readGeometry(&buffer, depth: depth + 1).shape)
        }
        return children
    }

    private static func readCoordinate(_ buffer: inout ByteBuffer, _ endianness: Endianness, _ descriptor: WKBTypeDescriptor) throws(PostgresError) -> PostgresCoordinate {
        let x = try readDouble(&buffer, endianness)
        let y = try readDouble(&buffer, endianness)
        switch descriptor.dimension {
        case .xy: return .xy(x: x, y: y)
        case .xyz: return .xyz(x: x, y: y, z: try readDouble(&buffer, endianness))
        case .xym: return .xym(x: x, y: y, m: try readDouble(&buffer, endianness))
        case .xyzm: return try readZM(&buffer, endianness, x: x, y: y)
        }
    }

    private static func readZM(_ buffer: inout ByteBuffer, _ endianness: Endianness, x: Double, y: Double) throws(PostgresError) -> PostgresCoordinate {
        let z = try readDouble(&buffer, endianness)
        return .xyzm(x: x, y: y, z: z, m: try readDouble(&buffer, endianness))
    }

    private static func readByteOrder(_ buffer: inout ByteBuffer) throws(PostgresError) -> Endianness {
        guard let flag = buffer.readInteger(as: UInt8.self) else {
            throw PostgresError.typeDecodingFailed(type: "PostgresGeometry", reason: "truncated WKB byte order")
        }
        return flag == 0 ? .big : .little
    }

    private static func readUInt32(_ buffer: inout ByteBuffer, _ endianness: Endianness) throws(PostgresError) -> UInt32 {
        guard let value = buffer.readInteger(endianness: endianness, as: UInt32.self) else {
            throw PostgresError.typeDecodingFailed(type: "PostgresGeometry", reason: "truncated WKB integer")
        }
        return value
    }

    private static func readDouble(_ buffer: inout ByteBuffer, _ endianness: Endianness) throws(PostgresError) -> Double {
        guard let bits = buffer.readInteger(endianness: endianness, as: UInt64.self) else {
            throw PostgresError.typeDecodingFailed(type: "PostgresGeometry", reason: "truncated WKB coordinate")
        }
        return Double(bitPattern: bits)
    }
}
