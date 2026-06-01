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

// Expands ClickHouse Geo alias type names to the structural types the
// server stores them as on the native wire. The server reports Geo
// columns by their alias name (Point, Ring, Polygon, MultiPolygon), and
// those aliases may appear nested inside Array(...), Tuple(...), Map(...),
// or Nullable(...). Expanding them once at the column-header boundary
// lets the existing Tuple/Array read and decode paths handle Geo columns
// with no per-type column code.
//
//   Point           -> Tuple(Float64, Float64)
//   Ring            -> Array(Tuple(Float64, Float64))
//   LineString      -> Array(Tuple(Float64, Float64))
//   Polygon         -> Array(Array(Tuple(Float64, Float64)))
//   MultiLineString -> Array(Array(Tuple(Float64, Float64)))
//   MultiPolygon    -> Array(Array(Array(Tuple(Float64, Float64))))
//
// A Nested(a A, b B) column kept unflattened (flatten_nested = 0) is
// reported with the Nested(...) name; it expands to its stored form
// Array(Tuple(a A, b B)) the same way, so the Array(Tuple(...)) read and
// decode paths handle it with no Nested-specific column code.
enum ClickHouseGeoTypeName {

    static func expand(_ typeName: String) -> String {
        switch typeName {
        case "Point": return point
        case "Ring": return ring
        case "LineString": return lineString
        case "Polygon": return polygon
        case "MultiLineString": return multiLineString
        case "MultiPolygon": return multiPolygon
        default: return expandComposite(typeName)
        }
    }

    private static let point = "Tuple(Float64, Float64)"
    private static let ring = "Array(\(point))"
    private static let lineString = "Array(\(point))"
    private static let polygon = "Array(\(ring))"
    private static let multiLineString = "Array(\(lineString))"
    private static let multiPolygon = "Array(\(polygon))"

    private static func expandComposite(_ typeName: String) -> String {
        let openIndex = firstParenthesis(typeName)
        guard openIndex < typeName.count else { return typeName }
        let head = String(typeName.prefix(openIndex))
        let inner = innerArguments(typeName, openIndex: openIndex)
        let arguments = splitTopLevel(inner)
        if head == "SimpleAggregateFunction" {
            return expandSimpleAggregateFunction(arguments)
        }
        let rendered = arguments.map { expandArgument($0) }.joined(separator: ", ")
        return reassemble(head: head, rendered: rendered)
    }

    // SimpleAggregateFunction(func, T) stores wire-identically to its inner
    // type T. The first argument is the aggregate function name and is
    // metadata only; the remaining arguments form the inner type, which we
    // expand recursively so any nested aliases resolve too.
    private static func expandSimpleAggregateFunction(_ arguments: [String]) -> String {
        guard arguments.count >= 2 else { return arguments.joined(separator: ", ") }
        let innerType = arguments.dropFirst().joined(separator: ", ")
        return expand(innerType)
    }

    private static func reassemble(head: String, rendered: String) -> String {
        if head == "Nested" {
            return "Array(Tuple(\(rendered)))"
        }
        return "\(head)(\(rendered))"
    }

    private static func expandArgument(_ argument: String) -> String {
        let nameSeparator = leadingNameLength(argument)
        guard nameSeparator > 0 else { return expand(argument) }
        let name = String(argument.prefix(nameSeparator))
        let type = String(argument.dropFirst(nameSeparator + 1))
        return "\(name) \(expand(type))"
    }

    private static func firstParenthesis(_ typeName: String) -> Int {
        let bytes = Array(typeName.utf8)
        for index in bytes.indices where bytes[index] == openParenthesis {
            return index
        }
        return bytes.count
    }

    private static func innerArguments(_ typeName: String, openIndex: Int) -> String {
        let bytes = Array(typeName.utf8)
        let interior = bytes[(openIndex + 1)..<(bytes.count - 1)]
        return String(decoding: Array(interior), as: UTF8.self)
    }

    private static func splitTopLevel(_ arguments: String) -> [String] {
        var pieces: [String] = []
        var current: [UInt8] = []
        var depth = 0
        for byte in arguments.utf8 {
            appendByte(byte, into: &current, pieces: &pieces, depth: &depth)
        }
        pieces.append(trimmed(current))
        return pieces
    }

    private static func appendByte(
        _ byte: UInt8,
        into current: inout [UInt8],
        pieces: inout [String],
        depth: inout Int
    ) {
        depth += depthDelta(byte)
        if isTopLevelDelimiter(byte, depth: depth) {
            pieces.append(trimmed(current))
            current.removeAll(keepingCapacity: true)
            return
        }
        current.append(byte)
    }

    private static func isTopLevelDelimiter(_ byte: UInt8, depth: Int) -> Bool {
        guard byte == comma else { return false }
        return depth == 0
    }

    private static func leadingNameLength(_ argument: String) -> Int {
        let bytes = Array(argument.utf8)
        var depth = 0
        for index in bytes.indices {
            depth += depthDelta(bytes[index])
            if isTopLevelSpace(bytes[index], depth: depth) { return index }
        }
        return 0
    }

    private static func isTopLevelSpace(_ byte: UInt8, depth: Int) -> Bool {
        guard byte == space else { return false }
        return depth == 0
    }

    private static func depthDelta(_ byte: UInt8) -> Int {
        if byte == openParenthesis { return 1 }
        if byte == closeParenthesis { return -1 }
        return 0
    }

    private static func trimmed(_ bytes: [UInt8]) -> String {
        var start = 0
        var end = bytes.count
        while start < end, bytes[start] == space { start += 1 }
        while end > start, bytes[end - 1] == space { end -= 1 }
        return String(decoding: Array(bytes[start..<end]), as: UTF8.self)
    }

    private static let openParenthesis: UInt8 = 0x28
    private static let closeParenthesis: UInt8 = 0x29
    private static let comma: UInt8 = 0x2C
    private static let space: UInt8 = 0x20
}
