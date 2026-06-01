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

extension PostgresPoint: PostgresDecodable {

    public static func decode(from value: PostgresDecodingValue) throws(PostgresError) -> PostgresPoint {
        switch value.format {
        case .text: return try PostgresGeometryText.point(value.text)
        case .binary: return try PostgresGeometryBinary.point(value)
        }
    }
}

extension PostgresPoint: PostgresEncodable {

    public func encodeToText() throws(PostgresError) -> PostgresCell {
        PostgresTextEncoding.text(description)
    }
}

extension PostgresLine: PostgresDecodable {

    public static func decode(from value: PostgresDecodingValue) throws(PostgresError) -> PostgresLine {
        switch value.format {
        case .text: return try PostgresGeometryText.line(value.text)
        case .binary: return try PostgresGeometryBinary.line(value)
        }
    }
}

extension PostgresLine: PostgresEncodable {

    public func encodeToText() throws(PostgresError) -> PostgresCell {
        PostgresTextEncoding.text(description)
    }
}

extension PostgresLineSegment: PostgresDecodable {

    public static func decode(from value: PostgresDecodingValue) throws(PostgresError) -> PostgresLineSegment {
        switch value.format {
        case .text: return try PostgresGeometryText.lineSegment(value.text)
        case .binary: return try PostgresGeometryBinary.lineSegment(value)
        }
    }
}

extension PostgresLineSegment: PostgresEncodable {

    public func encodeToText() throws(PostgresError) -> PostgresCell {
        PostgresTextEncoding.text(description)
    }
}

extension PostgresBox: PostgresDecodable {

    public static func decode(from value: PostgresDecodingValue) throws(PostgresError) -> PostgresBox {
        switch value.format {
        case .text: return try PostgresGeometryText.box(value.text)
        case .binary: return try PostgresGeometryBinary.box(value)
        }
    }
}

extension PostgresBox: PostgresEncodable {

    public func encodeToText() throws(PostgresError) -> PostgresCell {
        PostgresTextEncoding.text(description)
    }
}

extension PostgresPath: PostgresDecodable {

    public static func decode(from value: PostgresDecodingValue) throws(PostgresError) -> PostgresPath {
        switch value.format {
        case .text: return try PostgresGeometryText.path(value.text)
        case .binary: return try PostgresGeometryBinary.path(value)
        }
    }
}

extension PostgresPath: PostgresEncodable {

    public func encodeToText() throws(PostgresError) -> PostgresCell {
        PostgresTextEncoding.text(description)
    }
}

extension PostgresPolygon: PostgresDecodable {

    public static func decode(from value: PostgresDecodingValue) throws(PostgresError) -> PostgresPolygon {
        switch value.format {
        case .text: return try PostgresGeometryText.polygon(value.text)
        case .binary: return try PostgresGeometryBinary.polygon(value)
        }
    }
}

extension PostgresPolygon: PostgresEncodable {

    public func encodeToText() throws(PostgresError) -> PostgresCell {
        PostgresTextEncoding.text(description)
    }
}

extension PostgresCircle: PostgresDecodable {

    public static func decode(from value: PostgresDecodingValue) throws(PostgresError) -> PostgresCircle {
        switch value.format {
        case .text: return try PostgresGeometryText.circle(value.text)
        case .binary: return try PostgresGeometryBinary.circle(value)
        }
    }
}

extension PostgresCircle: PostgresEncodable {

    public func encodeToText() throws(PostgresError) -> PostgresCell {
        PostgresTextEncoding.text(description)
    }
}
