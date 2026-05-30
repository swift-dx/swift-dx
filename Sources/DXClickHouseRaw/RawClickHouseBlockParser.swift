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

// Inline wire-format parsing helpers operating directly on
// `UnsafePointer<UInt8>`. Mirrors the encoding rules used by
// `Sources/DXClickHouse/Internal/Codec/Binary/`, but without ByteBuffer
// or any NIO type. Every function takes a base pointer + offset + limit
// and returns the number of bytes consumed (or throws).

// Internal sentinel thrown by the pointer-pure parsing helpers when
// the input is well-formed but incomplete (the caller must read more
// bytes from the socket and retry) versus when the input is structurally
// malformed (the caller must surface a typed protocolError and tear the
// connection down). Kept package-internal so it never leaks into the
// public surface of RawClickHouseError; the connection layer is the
// single conversion boundary.
public enum RawClickHouseParseError: Error, Equatable, Sendable {

    case needsMoreBytes(stage: String)
    case malformed(stage: String, message: String)
}

public enum RawClickHouseWire {

    public static let uvarintMaxBytes = 10

    // Returns (value, consumedBytes). Throws `.needsMoreBytes` if the
    // limit is hit before the terminator bit, `.malformed` on >10-byte
    // overflows.
    @inlinable
    public static func readUVarInt(
        base: UnsafePointer<UInt8>, offset: Int, limit: Int
    ) throws(RawClickHouseParseError) -> (UInt64, Int) {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var byteIndex = 0
        while byteIndex < uvarintMaxBytes {
            let position = offset + byteIndex
            if position >= limit { throw .needsMoreBytes(stage: "uvarint") }
            let byte = base[position]
            if byte < 0x80 {
                if byteIndex == uvarintMaxBytes - 1, byte > 1 {
                    throw .malformed(stage: "uvarint", message: "overflow")
                }
                value |= UInt64(byte) << shift
                return (value, byteIndex + 1)
            }
            value |= UInt64(byte & 0x7F) << shift
            shift += 7
            byteIndex += 1
        }
        throw .malformed(stage: "uvarint", message: "overflow")
    }

    // Reads a length-prefixed string and returns (utf8Slice, consumedBytes).
    // The returned slice references arena memory; copy out before recv().
    @inlinable
    public static func readStringSlice(
        base: UnsafePointer<UInt8>, offset: Int, limit: Int,
        maxLength: Int = 1 << 30
    ) throws(RawClickHouseParseError) -> (UnsafeBufferPointer<UInt8>, Int) {
        let (declared, lengthBytes) = try readUVarInt(base: base, offset: offset, limit: limit)
        if declared > UInt64(maxLength) {
            throw .malformed(stage: "string", message: "declared length \(declared) exceeds max \(maxLength)")
        }
        let payloadLength = Int(declared)
        let payloadOffset = offset + lengthBytes
        if payloadOffset + payloadLength > limit {
            throw .needsMoreBytes(stage: "string body")
        }
        let buffer = UnsafeBufferPointer(start: base + payloadOffset, count: payloadLength)
        return (buffer, lengthBytes + payloadLength)
    }

    @inlinable
    public static func readString(
        base: UnsafePointer<UInt8>, offset: Int, limit: Int,
        maxLength: Int = 1 << 30
    ) throws(RawClickHouseParseError) -> (String, Int) {
        let (slice, consumed) = try readStringSlice(base: base, offset: offset, limit: limit, maxLength: maxLength)
        if slice.count == 0 { return ("", consumed) }
        let raw = UnsafeRawBufferPointer(slice)
        return (String(decoding: raw, as: Unicode.UTF8.self), consumed)
    }

    @inlinable
    public static func readFixedInt<T: FixedWidthInteger>(
        _ type: T.Type, base: UnsafePointer<UInt8>, offset: Int, limit: Int
    ) throws(RawClickHouseParseError) -> (T, Int) {
        let size = MemoryLayout<T>.size
        if offset + size > limit { throw .needsMoreBytes(stage: "fixed int") }
        var value: T = 0
        withUnsafeMutableBytes(of: &value) { destination in
            destination.copyMemory(from: UnsafeRawBufferPointer(start: base + offset, count: size))
        }
        return (T(littleEndian: value), size)
    }

    // Encoder helpers. `output` must have enough capacity (10 bytes for
    // a UVarInt, length-prefix + bytes for a string).
    @inlinable
    public static func writeUVarInt(_ value: UInt64, into output: inout [UInt8]) {
        var remaining = value
        while remaining >= 0x80 {
            output.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        output.append(UInt8(remaining))
    }

    @inlinable
    public static func writeString(_ value: String, into output: inout [UInt8]) {
        let utf8 = Array(value.utf8)
        writeUVarInt(UInt64(utf8.count), into: &output)
        output.append(contentsOf: utf8)
    }

    @inlinable
    public static func writeFixedInt<T: FixedWidthInteger>(_ value: T, into output: inout [UInt8]) {
        let little = value.littleEndian
        withUnsafeBytes(of: little) { bytes in
            output.append(contentsOf: bytes)
        }
    }
}

// Result of parsing a single Data-block body: a row count + a column
// metadata list. The body bytes themselves remain in the arena; the
// caller can re-read them through `RawClickHouseConnection.lastBlockBytes`
// if it wants to walk columns inline, or just consume the row count.
public struct RawClickHouseBlock {

    public let rowCount: Int
    public let columnCount: Int
    public let columnNames: [String]
    public let columnTypes: [String]
    public let bodyStart: Int
    public let bodyLength: Int

    public init(rowCount: Int, columnCount: Int, columnNames: [String], columnTypes: [String], bodyStart: Int, bodyLength: Int) {
        self.rowCount = rowCount
        self.columnCount = columnCount
        self.columnNames = columnNames
        self.columnTypes = columnTypes
        self.bodyStart = bodyStart
        self.bodyLength = bodyLength
    }
}

public enum RawClickHouseBlockParser {

    // Parses BlockInfo + (columnCount, rowCount) prologue. Stops at the
    // first column-name byte. The caller then reads each column's
    // name + type + serialization flag + body interleaved (CH wire
    // order) via `parseColumnHeader` and a per-type body skipper.
    @inlinable
    public static func parsePrologue(
        base: UnsafePointer<UInt8>, offset: Int, limit: Int
    ) throws(RawClickHouseParseError) -> (columnCount: Int, rowCount: Int, consumed: Int) {
        var cursor = offset
        cursor += try skipBlockInfo(base: base, offset: cursor, limit: limit)
        let (columnCountRaw, columnBytes) = try RawClickHouseWire.readUVarInt(base: base, offset: cursor, limit: limit)
        cursor += columnBytes
        let (rowCountRaw, rowBytes) = try RawClickHouseWire.readUVarInt(base: base, offset: cursor, limit: limit)
        cursor += rowBytes
        return (Int(columnCountRaw), Int(rowCountRaw), cursor - offset)
    }

    // Reads a single column header: name, type, hasCustomSerialization.
    // Returns the parsed strings and the bytes consumed. Does NOT touch
    // the column body — the caller skips/decodes it based on `type`.
    @inlinable
    public static func parseColumnHeader(
        base: UnsafePointer<UInt8>, offset: Int, limit: Int, revision: UInt64
    ) throws(RawClickHouseParseError) -> (name: String, type: String, consumed: Int) {
        var cursor = offset
        let (name, nameBytes) = try RawClickHouseWire.readString(base: base, offset: cursor, limit: limit)
        cursor += nameBytes
        let (type, typeBytes) = try RawClickHouseWire.readString(base: base, offset: cursor, limit: limit)
        cursor += typeBytes
        if revision >= 54_454 {
            if cursor >= limit { throw .needsMoreBytes(stage: "column header") }
            cursor += 1
        }
        return (name, type, cursor - offset)
    }

    @inlinable
    public static func skipBlockInfo(base: UnsafePointer<UInt8>, offset: Int, limit: Int) throws(RawClickHouseParseError) -> Int {
        var cursor = offset
        while true {
            let (fieldNumber, fieldBytes) = try RawClickHouseWire.readUVarInt(base: base, offset: cursor, limit: limit)
            cursor += fieldBytes
            switch fieldNumber {
            case 0:
                return cursor - offset
            case 1:
                if cursor >= limit { throw .needsMoreBytes(stage: "block info bool") }
                cursor += 1
            case 2:
                if cursor + 4 > limit { throw .needsMoreBytes(stage: "block info int32") }
                cursor += 4
            default:
                throw .malformed(stage: "block info", message: "unknown field \(fieldNumber)")
            }
        }
    }
}
