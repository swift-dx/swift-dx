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

import NIOCore

// Binary decoders for the built-in geometric types. Every coordinate is a
// big-endian float8; the composite shapes are fixed sequences of points, and
// `path`/`polygon` are length-prefixed point lists (`path` additionally carries a
// leading closed flag).
enum PostgresGeometryBinary {

    static func point(_ value: PostgresDecodingValue) throws(PostgresError) -> PostgresPoint {
        var buffer = ByteBuffer(bytes: value.bytes)
        return try readPoint(&buffer)
    }

    static func line(_ value: PostgresDecodingValue) throws(PostgresError) -> PostgresLine {
        var buffer = ByteBuffer(bytes: value.bytes)
        return PostgresLine(a: try double(&buffer), b: try double(&buffer), c: try double(&buffer))
    }

    static func lineSegment(_ value: PostgresDecodingValue) throws(PostgresError) -> PostgresLineSegment {
        var buffer = ByteBuffer(bytes: value.bytes)
        return PostgresLineSegment(start: try readPoint(&buffer), end: try readPoint(&buffer))
    }

    static func box(_ value: PostgresDecodingValue) throws(PostgresError) -> PostgresBox {
        var buffer = ByteBuffer(bytes: value.bytes)
        return PostgresBox(upperRight: try readPoint(&buffer), lowerLeft: try readPoint(&buffer))
    }

    static func circle(_ value: PostgresDecodingValue) throws(PostgresError) -> PostgresCircle {
        var buffer = ByteBuffer(bytes: value.bytes)
        return PostgresCircle(center: try readPoint(&buffer), radius: try double(&buffer))
    }

    static func path(_ value: PostgresDecodingValue) throws(PostgresError) -> PostgresPath {
        var buffer = ByteBuffer(bytes: value.bytes)
        guard let closed = buffer.readInteger(as: UInt8.self) else {
            throw PostgresError.typeDecodingFailed(type: "PostgresPath", reason: "truncated path flag")
        }
        return PostgresPath(isClosed: closed != 0, points: try readPoints(&buffer))
    }

    static func polygon(_ value: PostgresDecodingValue) throws(PostgresError) -> PostgresPolygon {
        var buffer = ByteBuffer(bytes: value.bytes)
        return PostgresPolygon(points: try readPoints(&buffer))
    }

    private static func readPoints(_ buffer: inout ByteBuffer) throws(PostgresError) -> [PostgresPoint] {
        guard let count = buffer.readInteger(endianness: .big, as: Int32.self) else {
            throw PostgresError.typeDecodingFailed(type: "geometry", reason: "truncated point count")
        }
        var points: [PostgresPoint] = []
        points.reserveCapacity(Int(count))
        for _ in 0..<count {
            points.append(try readPoint(&buffer))
        }
        return points
    }

    private static func readPoint(_ buffer: inout ByteBuffer) throws(PostgresError) -> PostgresPoint {
        PostgresPoint(x: try double(&buffer), y: try double(&buffer))
    }

    private static func double(_ buffer: inout ByteBuffer) throws(PostgresError) -> Double {
        guard let bits = buffer.readInteger(endianness: .big, as: UInt64.self) else {
            throw PostgresError.typeDecodingFailed(type: "geometry", reason: "truncated float8 coordinate")
        }
        return Double(bitPattern: bits)
    }
}
