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

// Text decoders for the geometric types. Their renderings differ only in the
// surrounding punctuation, so the shared `numbers` scanner extracts the embedded
// float8 coordinates and each shape assembles them. A `path` is open when its
// text begins with a square bracket and closed otherwise.
enum PostgresGeometryText {

    private static let numberCharacters = Set("0123456789.-+eE")

    static func point(_ text: String) throws(PostgresError) -> PostgresPoint {
        let values = try numbers(text)
        guard values.count == 2 else { throw malformed("point", text) }
        return PostgresPoint(x: values[0], y: values[1])
    }

    static func line(_ text: String) throws(PostgresError) -> PostgresLine {
        let values = try numbers(text)
        guard values.count == 3 else { throw malformed("line", text) }
        return PostgresLine(a: values[0], b: values[1], c: values[2])
    }

    static func lineSegment(_ text: String) throws(PostgresError) -> PostgresLineSegment {
        let values = try numbers(text)
        guard values.count == 4 else { throw malformed("lseg", text) }
        return PostgresLineSegment(start: PostgresPoint(x: values[0], y: values[1]), end: PostgresPoint(x: values[2], y: values[3]))
    }

    static func box(_ text: String) throws(PostgresError) -> PostgresBox {
        let values = try numbers(text)
        guard values.count == 4 else { throw malformed("box", text) }
        return PostgresBox(upperRight: PostgresPoint(x: values[0], y: values[1]), lowerLeft: PostgresPoint(x: values[2], y: values[3]))
    }

    static func circle(_ text: String) throws(PostgresError) -> PostgresCircle {
        let values = try numbers(text)
        guard values.count == 3 else { throw malformed("circle", text) }
        return PostgresCircle(center: PostgresPoint(x: values[0], y: values[1]), radius: values[2])
    }

    static func polygon(_ text: String) throws(PostgresError) -> PostgresPolygon {
        PostgresPolygon(points: try pairs(numbers(text)))
    }

    static func path(_ text: String) throws(PostgresError) -> PostgresPath {
        PostgresPath(isClosed: !text.hasPrefix("["), points: try pairs(numbers(text)))
    }

    private static func pairs(_ values: [Double]) throws(PostgresError) -> [PostgresPoint] {
        guard values.count % 2 == 0 else {
            throw PostgresError.typeDecodingFailed(type: "geometry", reason: "odd coordinate count")
        }
        var points: [PostgresPoint] = []
        var index = 0
        while index < values.count {
            points.append(PostgresPoint(x: values[index], y: values[index + 1]))
            index += 2
        }
        return points
    }

    private static func numbers(_ text: String) throws(PostgresError) -> [Double] {
        var values: [Double] = []
        var current = ""
        for character in text {
            try absorb(character, current: &current, into: &values)
        }
        try flush(&current, into: &values)
        return values
    }

    private static func absorb(_ character: Character, current: inout String, into values: inout [Double]) throws(PostgresError) {
        guard numberCharacters.contains(character) else {
            return try flush(&current, into: &values)
        }
        current.append(character)
    }

    private static func flush(_ current: inout String, into values: inout [Double]) throws(PostgresError) {
        guard !current.isEmpty else { return }
        guard let value = Double(current) else {
            throw PostgresError.typeDecodingFailed(type: "geometry", reason: "non-numeric coordinate '\(current)'")
        }
        values.append(value)
        current = ""
    }

    private static func malformed(_ type: String, _ text: String) -> PostgresError {
        .typeDecodingFailed(type: type, reason: "malformed geometry text '\(text)'")
    }
}
