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

// Decodes a PostgreSQL array column into its flattened element cells. The binary
// layout is self-describing — dimension count, the element type OID, per-dimension
// bounds, then each element prefixed with its length — so it carries everything
// the element decoders need. Multi-dimensional arrays are flattened in row-major
// order. The text rendering (`{1,2,3}`) is not parsed here yet: array columns
// arrive in binary on the extended (parameterized) query path, which is the
// supported route, so a text array reports a clear unsupported error instead.
enum PostgresArray {

    static func parse(_ value: PostgresDecodingValue) throws(PostgresError) -> PostgresArrayElements {
        switch value.format {
        case .binary: return try parseBinary(value)
        case .text: return try parseText(value)
        }
    }

    // Parses the one-dimensional text rendering `{a,"b,c",NULL}`: comma-separated
    // elements, each either an unquoted token (the literal `NULL` meaning a SQL
    // NULL) or a double-quoted string with `\\` and `\"` escapes. The element OID
    // is unknown on the text path, so it is reported as 0; the per-element text
    // decoders parse from the text regardless. Multi-dimensional text arrays are
    // not supported.
    private static func parseText(_ value: PostgresDecodingValue) throws(PostgresError) -> PostgresArrayElements {
        let bytes = value.bytes
        guard bytes.count >= 2, bytes.first == 0x7b, bytes.last == 0x7d else {
            throw PostgresError.typeDecodingFailed(type: "Array", reason: "malformed text array (missing braces)")
        }
        let inner = Array(bytes[(bytes.startIndex + 1)..<(bytes.endIndex - 1)])
        return PostgresArrayElements(elementObjectID: 0, format: .text, cells: try scanElements(inner))
    }

    private static func scanElements(_ inner: [UInt8]) throws(PostgresError) -> [PostgresCell] {
        guard !inner.isEmpty else { return [] }
        var cells: [PostgresCell] = []
        var index = 0
        while index < inner.count {
            let scanned = try scanElement(inner, from: index)
            cells.append(scanned.cell)
            index = scanned.end < inner.count ? scanned.end + 1 : scanned.end
        }
        return cells
    }

    private static func scanElement(_ inner: [UInt8], from start: Int) throws(PostgresError) -> (cell: PostgresCell, end: Int) {
        switch inner[start] {
        case 0x22: return try scanQuoted(inner, from: start)
        case 0x7b: throw PostgresError.typeDecodingFailed(type: "Array", reason: "multi-dimensional text arrays are not supported")
        default: return scanUnquoted(inner, from: start)
        }
    }

    private static func scanQuoted(_ inner: [UInt8], from start: Int) throws(PostgresError) -> (cell: PostgresCell, end: Int) {
        var bytes: [UInt8] = []
        var index = start + 1
        while index < inner.count {
            let byte = inner[index]
            if byte == 0x5c {
                guard index + 1 < inner.count else { break }
                bytes.append(inner[index + 1])
                index += 2
                continue
            }
            if byte == 0x22 { return (.bytes(bytes), index + 1) }
            bytes.append(byte)
            index += 1
        }
        throw PostgresError.typeDecodingFailed(type: "Array", reason: "unterminated quoted array element")
    }

    private static func scanUnquoted(_ inner: [UInt8], from start: Int) -> (cell: PostgresCell, end: Int) {
        var index = start
        while index < inner.count && inner[index] != 0x2c {
            index += 1
        }
        return (unquotedCell(Array(inner[start..<index])), index)
    }

    private static func unquotedCell(_ token: [UInt8]) -> PostgresCell {
        isNullToken(token) ? .sqlNull : .bytes(token)
    }

    private static func isNullToken(_ token: [UInt8]) -> Bool {
        token == [0x4e, 0x55, 0x4c, 0x4c] || token == [0x6e, 0x75, 0x6c, 0x6c]
    }

    private static func parseBinary(_ value: PostgresDecodingValue) throws(PostgresError) -> PostgresArrayElements {
        var buffer = ByteBuffer(bytes: value.bytes)
        guard let dimensionCount = buffer.readInteger(endianness: .big, as: Int32.self),
              buffer.readInteger(endianness: .big, as: Int32.self) != nil,
              let elementObjectID = buffer.readInteger(endianness: .big, as: UInt32.self) else {
            throw PostgresError.typeDecodingFailed(type: "Array", reason: "truncated array header")
        }
        guard dimensionCount > 0 else {
            return PostgresArrayElements(elementObjectID: elementObjectID, format: .binary, cells: [])
        }
        let count = try readDimensions(&buffer, dimensionCount: Int(dimensionCount))
        return PostgresArrayElements(elementObjectID: elementObjectID, format: .binary, cells: try readElements(&buffer, count: count))
    }

    private static func readDimensions(_ buffer: inout ByteBuffer, dimensionCount: Int) throws(PostgresError) -> Int {
        var count = 1
        for _ in 0..<dimensionCount {
            guard let length = buffer.readInteger(endianness: .big, as: Int32.self),
                  buffer.readInteger(endianness: .big, as: Int32.self) != nil else {
                throw PostgresError.typeDecodingFailed(type: "Array", reason: "truncated array dimension")
            }
            count *= Int(length)
        }
        return count
    }

    private static func readElements(_ buffer: inout ByteBuffer, count: Int) throws(PostgresError) -> [PostgresCell] {
        var cells: [PostgresCell] = []
        cells.reserveCapacity(count)
        for _ in 0..<count {
            cells.append(try readElement(&buffer))
        }
        return cells
    }

    private static func readElement(_ buffer: inout ByteBuffer) throws(PostgresError) -> PostgresCell {
        guard let length = buffer.readInteger(endianness: .big, as: Int32.self) else {
            throw PostgresError.typeDecodingFailed(type: "Array", reason: "truncated array element length")
        }
        return try elementCell(&buffer, length: Int(length))
    }

    private static func elementCell(_ buffer: inout ByteBuffer, length: Int) throws(PostgresError) -> PostgresCell {
        guard length >= 0 else { return .sqlNull }
        guard let bytes = buffer.readBytes(length: length) else {
            throw PostgresError.typeDecodingFailed(type: "Array", reason: "truncated array element of \(length) bytes")
        }
        return .bytes(bytes)
    }
}
